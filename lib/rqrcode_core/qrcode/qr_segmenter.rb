# frozen_string_literal: true

module RQRCodeCore
  # Splits a string into QR segments (numeric, alphanumeric, byte, kanji,
  # with ECI switches for byte segments) so the total encoded bit count is
  # minimal. All overheads are accounted for: segment mode indicators,
  # version-group dependent character count fields, and ECI designators.
  #
  # The character count field widths change across the three version
  # groups (1-9, 10-26, 27-40), so the optimal segmentation is computed
  # per version group.
  class QRSegmenter
    # Representative version of each version group, used to look up
    # character count field widths via QRUtil.get_length_in_bits.
    GROUP_VERSION = [1, 10, 27].freeze

    MODE_INDEX = {
      mode_number: 0,
      mode_alpha_numk: 1,
      mode_8bit_byte: 2,
      mode_kanji: 3
    }.freeze

    # Maps mode indexes to the mode names accepted by QRSegment.
    INDEX_MODE_NAME = {
      0 => :number,
      1 => :alphanumeric,
      2 => :byte_8bit,
      3 => :kanji
    }.freeze

    # ECI contexts a byte segment can be written in. :none means no ECI
    # segment has been emitted; once left it cannot be re-entered.
    ECI_INDEX = {none: 0, utf8: 1, shift_jis: 2}.freeze
    ECI_ASSIGNMENT = {utf8: 26, shift_jis: 20}.freeze

    # 4 bit mode indicator + 8 bit designator (assignments below 128).
    ECI_SWITCH_COST = 4 + 8

    BYTE_MODE = MODE_INDEX[:mode_8bit_byte]
    START_MODE = -1 # pseudo mode: no segment opened yet

    class << self
      # Array of {data:, mode:} hashes minimizing the encoded bit count.
      def segment(data, version_group: 0)
        new(data, version_group).segments
      end

      # Minimal encoded bit count for the string in the given version group.
      def minimum_bits(data, version_group: 0)
        new(data, version_group).minimum_bits
      end
    end

    def initialize(data, version_group = 0)
      @chars = data.chars
      @header_cost = {}
      MODE_INDEX.each do |mode, index|
        @header_cost[index] = 4 + QRUtil.get_length_in_bits(QRMODE[mode], GROUP_VERSION[version_group])
      end
      @byte_costs = @chars.map { |char| byte_costs_for(char) }
      @candidates = @chars.each_with_index.map { |char, pos| candidates_for(char, pos) }
    end

    def segments
      run_dp
      build_segments
    end

    def minimum_bits
      run_dp
      @best_cost
    end

    private

    # ECI context => content bits for the char in a byte segment. The
    # :shift_jis context is absent when the char cannot be represented
    # in Shift_JIS.
    def byte_costs_for(char)
      costs = {
        ECI_INDEX[:none] => char.bytesize * 8,
        ECI_INDEX[:utf8] => char.encode(Encoding::UTF_8).bytesize * 8
      }
      begin
        costs[ECI_INDEX[:shift_jis]] = char.encode(Encoding::Shift_JIS).bytesize * 8
      rescue EncodingError
        # not representable in Shift_JIS
      end
      costs
    end

    # [mode_index, eci_index] pairs the char can continue/open. The ECI
    # index is only meaningful for byte mode candidates.
    def candidates_for(char, pos)
      cands = []
      cands << [MODE_INDEX[:mode_number], 0] if NUMERIC.include?(char)
      cands << [MODE_INDEX[:mode_alpha_numk], 0] if ALPHANUMERIC.include?(char)
      cands << [MODE_INDEX[:mode_kanji], 0] if QRKanji.kanji_code(char)
      @byte_costs[pos].each_key do |eci|
        cands << [BYTE_MODE, eci]
      end
      cands
    end

    # Marginal content bits when appending a char to an open segment.
    # Numeric and alphanumeric costs depend on the position within the
    # current group (3 chars/10 bits and 2 chars/11 bits respectively).
    def marginal_cost(mode, phase, pos, eci)
      case mode
      when MODE_INDEX[:mode_number]
        (phase == 0) ? 4 : 3
      when MODE_INDEX[:mode_alpha_numk]
        (phase == 0) ? 6 : 5
      when MODE_INDEX[:mode_kanji]
        13
      else
        @byte_costs[pos][eci]
      end
    end

    def next_phase(mode, phase)
      case mode
      when MODE_INDEX[:mode_number]
        (phase + 1) % 3
      when MODE_INDEX[:mode_alpha_numk]
        (phase + 1) % 2
      else
        0
      end
    end

    def run_dp
      return if @best_cost

      # state: [mode_index, phase, eci_index] => cost
      costs = {[START_MODE, 0, ECI_INDEX[:none]] => 0}
      @parents = {}

      @chars.each_index do |pos|
        next_costs = {}
        costs.each do |state, cost|
          mode, phase, eci = state
          @candidates[pos].each do |cand_mode, cand_eci|
            if mode != START_MODE && cand_mode == mode && (cand_mode != BYTE_MODE || cand_eci == eci)
              # continue the open segment
              new_state = [mode, next_phase(mode, phase), eci]
              relax(next_costs, pos, new_state, cost + marginal_cost(mode, phase, pos, eci), state, false, false)
            else
              # open a new segment (plus an ECI switch when needed)
              # the :none context has no ECI designator, so once left it
              # cannot be re-entered
              next if cand_mode == BYTE_MODE && cand_eci != eci && cand_eci == ECI_INDEX[:none]

              extra = @header_cost[cand_mode]
              new_eci = eci
              switched = false
              if cand_mode == BYTE_MODE && cand_eci != eci
                extra += ECI_SWITCH_COST
                new_eci = cand_eci
                switched = true
              end
              new_state = [cand_mode, next_phase(cand_mode, 0), new_eci]
              relax(next_costs, pos, new_state, cost + extra + marginal_cost(cand_mode, 0, pos, new_eci), state, true, switched)
            end
          end
        end
        costs = next_costs
      end

      @best_state, @best_cost = costs.min_by { |_state, cost| cost }
    end

    def relax(next_costs, pos, new_state, cost, prev_state, opened, switched)
      if cost < (next_costs[new_state] || Float::INFINITY)
        next_costs[new_state] = cost
        @parents[[pos, new_state]] = [prev_state, opened, switched]
      end
    end

    def build_segments
      steps = []
      state = @best_state
      pos = @chars.length - 1
      while pos >= 0
        prev_state, opened, switched = @parents[[pos, state]]
        steps.unshift([state, opened, switched])
        state = prev_state
        pos -= 1
      end

      segments = []
      steps.each_with_index do |(state, opened, switched), i|
        mode, _phase, eci = state
        if opened
          segments << {data: ECI_ASSIGNMENT[ECI_INDEX.key(eci)], mode: :eci} if switched
          segments << {data: +"", mode: INDEX_MODE_NAME[mode], eci: eci}
        end
        segments.last[:data] << @chars[i]
      end
      segments.map do |seg|
        data = seg[:data]
        if seg[:mode] == :byte_8bit && seg[:eci] == ECI_INDEX[:shift_jis]
          data = data.encode(Encoding::Shift_JIS)
        elsif seg[:mode] == :byte_8bit && seg[:eci] == ECI_INDEX[:utf8]
          data = data.encode(Encoding::UTF_8)
        end
        seg.slice(:data, :mode).merge(data: data)
      end
    end
  end
end
