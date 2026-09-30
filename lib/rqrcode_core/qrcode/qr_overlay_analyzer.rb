# frozen_string_literal: true

module RQRCodeCore
  # QROverlayAnalyzer evaluates how covering modules of an already-encoded
  # QR symbol (for example, when placing a logo in the center) spends its
  # error correction budget.
  #
  # Given a QRCode and a set of [row, column] module coordinates to cover,
  # it reports, per Reed-Solomon block, how many codewords are affected and
  # how much error correction margin remains. Function modules (finder,
  # timing, alignment, format info, version info, dark module) are reported
  # separately and never counted against the data error correction budget.
  #
  # The analysis is read-only: it never mutates the given QRCode. It is also
  # conservative -- it is a bound under stated assumptions, not a guarantee
  # of decodability. See QROverlayAnalyzer::ASSUMPTIONS.
  #
  #   qr = RQRCodeCore::QRCode.new("https://kyan.com", level: :h)
  #   report = RQRCodeCore::QROverlayAnalyzer.analyze(qr, [[10, 10], [10, 11]])
  #   report[:blocks].first[:remaining_margin] # => erasures still absorbable
  #
  class QROverlayAnalyzer
    FUNCTION_CATEGORIES = %i[finder timing alignment format_info version_info dark_module].freeze

    # Remainder bits per version (index 0 == version 1), per ISO/IEC 18004.
    REMAINDER_BITS = [
      0, # version 1
      7, 7, 7, 7, 7, # versions 2-6
      0, 0, 0, 0, 0, 0, 0, # versions 7-13
      3, 3, 3, 3, 3, 3, 3, # versions 14-20
      4, 4, 4, 4, 4, 4, 4, # versions 21-27
      3, 3, 3, 3, 3, 3, 3, # versions 28-34
      0, 0, 0, 0, 0, 0 # versions 35-40
    ].freeze

    # The report is a conservative bound under these assumptions, included
    # in every report under the :assumptions key.
    ASSUMPTIONS = [
      "Covered modules are assumed fully unreadable; covering any single bit of a codeword renders the whole codeword unreadable.",
      "Each distinct codeword is counted at most once, no matter how many of its modules are covered.",
      "Covered codewords are treated as erasures at known positions: a block with ec_count parity codewords recovers up to ec_count erasures.",
      "reserved_errors reserves 2 parity codewords per block for each anticipated additional error at an unknown position.",
      "Function modules are not protected by the Reed-Solomon budget; damaging them may make the symbol undetectable regardless of the remaining margin.",
      "This report is a conservative bound under these assumptions, not a guarantee that the symbol will decode."
    ].freeze

    attr_reader :version, :error_correction_level, :module_count

    def self.analyze(qr_code, coordinates, reserved_errors: 0)
      new(qr_code).analyze(coordinates, reserved_errors: reserved_errors)
    end

    def initialize(qr_code)
      @version = qr_code.version
      @error_correction_level = qr_code.error_correction_level
      @module_count = qr_code.module_count
      @rs_blocks = QRRSBlock.get_rs_blocks(@version, QRERRORCORRECTLEVEL[@error_correction_level])
      @cell_map = build_cell_map
      @codeword_map = build_codeword_map
    end

    # Analyze covering the given [row, column] module coordinates.
    #
    # coordinates - an enumerable of [row, column] Integer pairs
    # reserved_errors - non-negative Integer; parity codewords (2 per error)
    #                   set aside in every block for errors at unknown positions
    #
    # Returns a Hash describing affected codewords per RS block, remaining
    # error correction margin, separately reported function modules, and the
    # assumptions the conservative bound is based on.
    def analyze(coordinates, reserved_errors: 0)
      validate_reserved_errors!(reserved_errors)
      coords = normalize_coordinates(coordinates)

      affected = {}
      function_hits = Hash.new { |hash, key| hash[key] = [] }
      remainder_hits = 0

      coords.each do |row, col|
        cell = @cell_map[row][col]
        case cell
        when Integer
          affected[cell] = true
        when :remainder
          remainder_hits += 1
        else
          function_hits[cell] << [row, col]
        end
      end

      per_block = @rs_blocks.map { {data: 0, ec: 0} }
      affected.each_key do |codeword_index|
        block_index, kind = @codeword_map[codeword_index]
        per_block[block_index][kind] += 1
      end

      blocks = @rs_blocks.each_with_index.map do |rs_block, index|
        ec_count = rs_block.total_count - rs_block.data_count
        affected_total = per_block[index][:data] + per_block[index][:ec]
        remaining_margin = ec_count - (2 * reserved_errors) - affected_total

        {
          index: index,
          total_count: rs_block.total_count,
          data_count: rs_block.data_count,
          ec_count: ec_count,
          affected_data_codewords: per_block[index][:data],
          affected_ec_codewords: per_block[index][:ec],
          affected_codewords: affected_total,
          erasure_capacity: ec_count,
          reserved_errors: reserved_errors,
          remaining_margin: remaining_margin,
          recoverable: remaining_margin >= 0
        }
      end

      function_modules = {}
      FUNCTION_CATEGORIES.each do |category|
        hits = function_hits[category] || []
        function_modules[category] = {count: hits.size, coordinates: hits}
      end

      {
        version: @version,
        error_correction_level: @error_correction_level,
        module_count: @module_count,
        reserved_errors: reserved_errors,
        covered_module_count: coords.size,
        affected_codewords: affected.size,
        remainder_bits_covered: remainder_hits,
        blocks: blocks,
        function_modules: function_modules,
        recoverable: blocks.all? { |block| block[:recoverable] },
        assumptions: ASSUMPTIONS
      }
    end

    # The [row, column] positions of the 8 modules carrying the given
    # interleaved codeword index. Useful for choosing or visualizing
    # coordinates to pass to #analyze.
    def codeword_positions(codeword_index)
      validate_codeword_index!(codeword_index)

      positions = []
      @cell_map.each_with_index do |row_cells, row|
        row_cells.each_with_index do |cell, col|
          positions << [row, col] if cell == codeword_index
        end
      end
      positions
    end

    # The [row, column] positions of the remainder bits, which carry no data.
    def remainder_positions
      positions = []
      @cell_map.each_with_index do |row_cells, row|
        row_cells.each_with_index do |cell, col|
          positions << [row, col] if cell == :remainder
        end
      end
      positions
    end

    # The [block_index, :data/:ec, position_in_block] the given interleaved
    # codeword index belongs to.
    def codeword_location(codeword_index)
      validate_codeword_index!(codeword_index)

      @codeword_map[codeword_index]
    end

    private

    # Rebuilds, for every module, what it carries: a function module category
    # (Symbol), an interleaved codeword index (Integer) or :remainder.
    # Mirrors the placement and zigzag traversal logic of QRCode.
    def build_cell_map
      map = Array.new(@module_count) { Array.new(@module_count) }
      place_finder_patterns(map)
      place_alignment_patterns(map)
      place_timing_pattern(map)
      place_format_info(map)
      place_version_info(map)
      map[@module_count - 8][8] = :dark_module
      place_data(map)
      map
    end

    def place_finder_patterns(map)
      [[0, 0], [0, @module_count - 8], [@module_count - 8, 0]].each do |row0, col0|
        (row0...(row0 + 8)).each do |row|
          (col0...(col0 + 8)).each do |col|
            map[row][col] = :finder
          end
        end
      end
    end

    def place_alignment_patterns(map)
      positions = QRUtil.get_pattern_positions(@version)
      positions.each do |row|
        positions.each do |col|
          next unless map[row][col].nil?

          ((row - 2)..(row + 2)).each do |r|
            ((col - 2)..(col + 2)).each do |c|
              map[r][c] ||= :alignment
            end
          end
        end
      end
    end

    def place_timing_pattern(map)
      (8...@module_count - 8).each do |i|
        map[i][6] ||= :timing
        map[6][i] ||= :timing
      end
    end

    def place_format_info(map)
      QRFORMATINFOLENGTH.times do |i|
        row = if i < 6
          i
        elsif i < 8
          i + 1
        else
          @module_count - 15 + i
        end
        map[row][8] = :format_info

        col = if i < 8
          @module_count - i - 1
        elsif i < 9
          15 - i
        else
          15 - i - 1
        end
        map[8][col] = :format_info
      end
    end

    def place_version_info(map)
      return if @version < 7

      18.times do |i|
        map[(i / 3).floor][i % 3 + @module_count - 11] = :version_info
        map[i % 3 + @module_count - 11][(i / 3).floor] = :version_info
      end
    end

    # Replays the zigzag data placement of QRCode#map_data, assigning each
    # data module its interleaved codeword index (or :remainder).
    def place_data(map)
      total_bits = @rs_blocks.sum(&:total_count) * 8
      inc = -1
      row = @module_count - 1
      position = 0

      (@module_count - 1).step(1, -2) do |col|
        col -= 1 if col <= 6

        loop do
          2.times do |c|
            current = col - c
            next if current.negative?

            if map[row][current].nil?
              map[row][current] = (position < total_bits) ? position / 8 : :remainder
              position += 1
            end
          end

          row += inc

          if row < 0 || @module_count <= row
            row -= inc
            inc = -inc
            break
          end
        end
      end

      expected = total_bits + REMAINDER_BITS[@version - 1]
      if position != expected
        raise QRCodeRunTimeError, "module mapping inconsistent @ version: #{@version} (#{position} != #{expected})"
      end
    end

    # Maps each interleaved codeword index back to
    # [block_index, :data/:ec, position_in_block], mirroring QRCode.create_bytes.
    def build_codeword_map
      max_dc_count = @rs_blocks.map(&:data_count).max
      max_ec_count = @rs_blocks.map { |block| block.total_count - block.data_count }.max
      map = []

      max_dc_count.times do |i|
        @rs_blocks.each_with_index do |block, r|
          map << [r, :data, i] if i < block.data_count
        end
      end

      max_ec_count.times do |i|
        @rs_blocks.each_with_index do |block, r|
          map << [r, :ec, i] if i < block.total_count - block.data_count
        end
      end

      map
    end

    def validate_reserved_errors!(reserved_errors)
      unless reserved_errors.is_a?(Integer) && reserved_errors >= 0
        raise QRCodeArgumentError, "reserved_errors must be a non-negative Integer: #{reserved_errors.inspect}"
      end
    end

    def validate_codeword_index!(codeword_index)
      unless codeword_index.is_a?(Integer) && codeword_index.between?(0, @codeword_map.size - 1)
        raise QRCodeArgumentError, "Unknown codeword index: #{codeword_index.inspect}"
      end
    end

    def normalize_coordinates(coordinates)
      unless coordinates.respond_to?(:map)
        raise QRCodeArgumentError, "coordinates must be an enumerable of [row, column] pairs"
      end

      seen = {}
      coordinates.filter_map do |pair|
        unless pair.is_a?(Array) && pair.size == 2 && pair.all? { |value| value.is_a?(Integer) }
          raise QRCodeArgumentError, "coordinates must be [row, column] pairs of Integers: #{pair.inspect}"
        end

        row, col = pair
        unless row.between?(0, @module_count - 1) && col.between?(0, @module_count - 1)
          raise QRCodeArgumentError, "coordinate out of bounds for #{@module_count}x#{@module_count} symbol: #{pair.inspect}"
        end

        key = row * @module_count + col
        next if seen[key]

        seen[key] = true
        [row, col]
      end
    end
  end
end
