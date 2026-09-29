# frozen_string_literal: true

module RQRCodeCore
  # Splits a string into a sequence of QR segments (numeric, alphanumeric,
  # kanji and byte with optional ECI headers) that minimises the total
  # number of bits, then reports the smallest QR version that fits.
  #
  # The optimisation accounts for:
  # * the 4-bit mode indicator of every segment
  # * the character count indicator, whose size changes across the
  #   version groups 1-9, 10-26 and 27-40
  # * ECI headers (and switches between them) needed by byte segments
  #
  # Byte segments may be emitted in ISO-8859-1 (the default interpretation,
  # no ECI header), UTF-8 (ECI 26) or Shift_JIS (ECI 20), whichever is
  # cheapest. Once an ECI header is emitted it stays in effect, so a byte
  # segment can only fall back to the default interpretation when no ECI
  # header has been emitted yet.
  class QRSegmenter
    ECI_UTF8 = QRECI::ASSIGNMENTS[:utf8]
    ECI_SHIFT_JIS = QRECI::ASSIGNMENTS[:shift_jis]

    # Character count indicator sizes are constant within each group
    VERSION_GROUPS = [(1..9), (10..26), (27..40)].freeze

    # Byte encodings considered, with the ECI assignment number that has to
    # be in effect for each (nil = default interpretation, no ECI header)
    BYTE_ENCODINGS = {
      default: nil,
      utf8: ECI_UTF8,
      shift_jis: ECI_SHIFT_JIS
    }.freeze

    # ECI states the optimiser tracks (nil = no ECI header emitted yet)
    ECI_STATES = [nil, ECI_UTF8, ECI_SHIFT_JIS].freeze

    # Residue adjustments making the grouped content bit counts separable:
    # 3 * numeric_bits(len) == 10 * len + NUMERIC_ADJUST[len % 3]
    # 2 * alphanumeric_bits(len) == 11 * len + ALPHANUMERIC_ADJUST[len % 2]
    NUMERIC_ADJUST = [0, 2, 1].freeze
    ALPHANUMERIC_ADJUST = [0, 1].freeze

    def self.segment(data, level: :h)
      new(data, level).segment
    end

    def initialize(data, level)
      unless QRMAXBITS.key?(level)
        raise QRCodeArgumentError, "Unknown error correction level `#{level.inspect}`"
      end

      @chars = data.chars
      @length = @chars.length
      @level = level
      prepare_char_tables
    end

    # Returns an array of {data:, mode:} hashes accepted by QRCode.
    def segment
      return [] if @length.zero?

      fallback = nil
      VERSION_GROUPS.each do |group|
        bits, segments = optimize_for_group(group)
        # Data cannot be transcoded at all (e.g. invalid byte sequences):
        # fall back to writing the raw bytes, matching single-segment behaviour.
        return [{data: @chars.join, mode: :byte_8bit}] if segments.nil?

        fallback ||= segments
        return segments if minimum_version_in_group(group, bits)
      end

      # Nothing fits: hand back the last group's segments and let QRCode
      # raise its standard "data too long" error.
      fallback
    end

    private

    def prepare_char_tables
      @numeric_ok = @chars.map { |char| NUMERIC.include?(char) }
      @alphanumeric_ok = @chars.map { |char| ALPHANUMERIC.include?(char) }
      @kanji_ok = @chars.map { |char| QRKanji.kanji_char?(char) }
      @byte_sizes = BYTE_ENCODINGS.keys.to_h do |encoding|
        [encoding, @chars.map { |char| byte_size(char, encoding) }]
      end
      @byte_prefix = @byte_sizes.transform_values do |sizes|
        sizes.each_with_object([0]) { |size, prefix| prefix << prefix.last + (size || 0) }
      end
    end

    def byte_size(char, encoding)
      case encoding
      when :default
        char.encode(Encoding::ISO_8859_1).bytesize
      when :utf8
        char.encode(Encoding::UTF_8).bytesize
      when :shift_jis
        char.encode(Encoding::SHIFT_JIS).bytesize
      end
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      nil
    end

    def optimize_for_group(group)
      header = {
        number: 4 + QRUtil.get_length_in_bits(QRMODE[:mode_number], group.first),
        alphanumeric: 4 + QRUtil.get_length_in_bits(QRMODE[:mode_alpha_numk], group.first),
        kanji: 4 + QRUtil.get_length_in_bits(QRMODE[:mode_kanji], group.first),
        byte: 4 + QRUtil.get_length_in_bits(QRMODE[:mode_8bit_byte], group.first)
      }

      # dp[i][eci] = [cost, [prev_i, prev_eci, action]]
      dp = Array.new(@length + 1)
      dp[0] = {nil => [0, nil]}

      # Running minima over every position a segment could start at, making
      # each mode transition O(1) per position. Entries are
      # [scaled_cost, source_index, source_eci]; trackers are cleared
      # whenever a character breaks the mode's run.
      numeric = {}
      alphanumeric = {}
      kanji = {}
      byte = BYTE_ENCODINGS.keys.to_h { |encoding| [encoding, {}] }

      (0..@length).each do |j|
        if j > 0
          numeric.clear unless @numeric_ok[j - 1]
          alphanumeric.clear unless @alphanumeric_ok[j - 1]
          kanji.clear unless @kanji_ok[j - 1]
          BYTE_ENCODINGS.each_key { |encoding| byte[encoding].clear unless @byte_sizes[encoding][j - 1] }

          arrive(dp, j, header, numeric, alphanumeric, kanji, byte)
        end

        register(dp[j], j, numeric, alphanumeric, kanji, byte)
      end

      final = dp[@length]
      return [nil, nil] if final.nil?

      final_eci, (bits,) = final.min_by { |_, (cost, _)| cost }
      [bits, build_segments(dp, final_eci)]
    end

    # Closes segments ending at position j from the running minima
    def arrive(dp, j, header, numeric, alphanumeric, kanji, byte)
      ECI_STATES.each do |eci|
        3.times do |residue|
          entry = numeric[[eci, residue]]
          next unless entry

          scaled, i, = entry
          rem = (j % 3 - residue) % 3
          total = 3 * header[:number] + 10 * j + scaled + NUMERIC_ADJUST[rem]
          relax(dp, j, eci, total / 3, [i, eci, [:number, i, j]])
        end

        2.times do |residue|
          entry = alphanumeric[[eci, residue]]
          next unless entry

          scaled, i, = entry
          rem = (j % 2 - residue) % 2
          total = 2 * header[:alphanumeric] + 11 * j + scaled + ALPHANUMERIC_ADJUST[rem]
          relax(dp, j, eci, total / 2, [i, eci, [:alphanumeric, i, j]])
        end

        if (entry = kanji[eci])
          offset, i, = entry
          relax(dp, j, eci, header[:kanji] + 13 * j + offset, [i, eci, [:kanji, i, j]])
        end
      end

      BYTE_ENCODINGS.each do |encoding, eci_after|
        prefix = @byte_prefix[encoding]

        byte[encoding].each do |eci, (offset, i)|
          next if eci_after.nil? && !eci.nil? # an emitted ECI header cannot be revoked

          switch = (eci_after == eci) ? 0 : 4 + QRECI.designator_bits(eci_after)
          total = header[:byte] + switch + 8 * prefix[j] + offset
          relax(dp, j, eci_after, total, [i, eci, [:byte, i, j, encoding]])
        end
      end
    end

    # Opens segments starting at position j from the finalised costs
    def register(dp_j, j, numeric, alphanumeric, kanji, byte)
      return if dp_j.nil? || j >= @length

      dp_j.each do |eci, (cost, _)|
        keep_minimum(numeric, [eci, j % 3], 3 * cost - 10 * j, j, eci) if @numeric_ok[j]
        keep_minimum(alphanumeric, [eci, j % 2], 2 * cost - 11 * j, j, eci) if @alphanumeric_ok[j]
        keep_minimum(kanji, eci, cost - 13 * j, j, eci) if @kanji_ok[j]

        BYTE_ENCODINGS.each_key do |encoding|
          if @byte_sizes[encoding][j]
            keep_minimum(byte[encoding], eci, cost - 8 * @byte_prefix[encoding][j], j, eci)
          end
        end
      end
    end

    def keep_minimum(tracker, key, scaled, i, eci)
      current = tracker[key]
      tracker[key] = [scaled, i, eci] if current.nil? || scaled < current[0]
    end

    def relax(dp, j, eci, cost, parent)
      dp[j] ||= {}
      current = dp[j][eci]
      dp[j][eci] = [cost, parent] if current.nil? || cost < current[0]
    end

    def build_segments(dp, final_eci)
      segments = []
      j = @length
      eci = final_eci

      while j > 0
        prev_i, prev_eci, action = dp[j][eci][1]
        segments.unshift(build_segment(action))
        if action[0] == :byte && BYTE_ENCODINGS[action[3]] != prev_eci
          segments.unshift({data: BYTE_ENCODINGS[action[3]], mode: :eci})
        end
        j = prev_i
        eci = prev_eci
      end

      segments
    end

    def build_segment(action)
      mode, i, j, encoding = action
      data = @chars[i...j].join

      case mode
      when :number
        {data: data, mode: :number}
      when :alphanumeric
        {data: data, mode: :alphanumeric}
      when :kanji
        {data: data, mode: :kanji}
      when :byte
        {data: encode_byte_data(data, encoding), mode: :byte_8bit}
      end
    end

    def encode_byte_data(data, encoding)
      case encoding
      when :utf8 then data.encode(Encoding::UTF_8)
      when :shift_jis then data.encode(Encoding::SHIFT_JIS)
      else data.encode(Encoding::ISO_8859_1)
      end
    end

    def minimum_version_in_group(group, bits)
      group.each do |version|
        return version if bits < QRMAXBITS[@level][version - 1]
      end
      nil
    end
  end
end
