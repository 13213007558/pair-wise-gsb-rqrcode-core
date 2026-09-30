# frozen_string_literal: true

module RQRCodeCore
  # Read-only analysis of how covering a set of modules (e.g. placing a logo
  # over the center of a symbol) impacts the error correction budget of an
  # already encoded QRCode.
  #
  # Instead of the unreliable "a logo may cover at most X% of the area" rule
  # of thumb, this analysis maps every covered module back to the exact
  # Reed-Solomon block and codeword it belongs to (de-interleaving the final
  # codeword stream) and reports, per block, how many codewords are affected
  # and how much error correction headroom remains.
  #
  #   qr = RQRCodeCore::QRCode.new("https://kyan.com", level: :h)
  #   report = RQRCodeCore::QROverlayAnalysis.analyze(qr, [[10, 10], [10, 11]], reserve_errors: 2)
  #   report.correctable? # => true/false
  #   report.blocks.first.remaining_margin # => erasures this block can still absorb
  #
  # The analysis never modifies the given QRCode; it only reads +version+,
  # +module_count+ and +error_correction_level+.
  class QROverlayAnalysis
    # Why the numbers are conservative bounds. Included in every report.
    ASSUMPTIONS = [
      "Every covered module is assumed to corrupt its whole codeword; a codeword is counted once no matter how many of its modules are covered.",
      "Affected codewords are treated as erasures at known positions: each consumes 1 error-correction codeword of its RS block.",
      "Each reserved unknown-location error consumes 2 error-correction codewords in every block.",
      "Function modules (position, timing, alignment, format, version) and remainder bits are reported separately and never consume the data error-correction budget.",
      "The report is a conservative bound under these assumptions; actual decodability may be better."
    ].freeze

    FUNCTION_CATEGORIES = %i[position timing alignment format version].freeze

    # Per-RS-block impact of the overlay.
    class BlockReport
      attr_reader :index, :data_count, :ec_count, :affected_data_codewords,
        :affected_ec_codewords, :reserved_errors

      def initialize(index:, data_count:, ec_count:, affected_data_codewords:, affected_ec_codewords:, reserved_errors:)
        @index = index
        @data_count = data_count
        @ec_count = ec_count
        @affected_data_codewords = affected_data_codewords
        @affected_ec_codewords = affected_ec_codewords
        @reserved_errors = reserved_errors
      end

      # Distinct codewords (data + ec) of this block hit by the overlay.
      def affected_total
        @affected_data_codewords + @affected_ec_codewords
      end

      # Number of additional known-position erasures this block can still
      # absorb after the overlay damage and the reserved unknown-location
      # errors. Unknown-location errors each cost 2 codewords.
      def remaining_margin
        @ec_count - affected_total - (2 * @reserved_errors)
      end

      def correctable?
        remaining_margin >= 0
      end

      def to_h
        {
          index: @index,
          data_count: @data_count,
          ec_count: @ec_count,
          affected_data_codewords: @affected_data_codewords,
          affected_ec_codewords: @affected_ec_codewords,
          affected_total: affected_total,
          reserved_errors: @reserved_errors,
          remaining_margin: remaining_margin,
          correctable: correctable?
        }
      end
    end

    # Aggregate result of an overlay analysis.
    class Report
      attr_reader :version, :error_correction_level, :module_count,
        :reserve_errors, :blocks, :function_modules, :remainder_modules,
        :assumptions

      def initialize(version:, error_correction_level:, module_count:, reserve_errors:, blocks:, function_modules:, remainder_modules:)
        @version = version
        @error_correction_level = error_correction_level
        @module_count = module_count
        @reserve_errors = reserve_errors
        @blocks = blocks.freeze
        @function_modules = function_modules.freeze
        @remainder_modules = remainder_modules.freeze
        @assumptions = ASSUMPTIONS
      end

      # True when every RS block can still absorb the overlay damage plus
      # the reserved unknown-location errors.
      def correctable?
        @blocks.all?(&:correctable?)
      end

      # Total distinct data/ec codewords affected across all blocks.
      def affected_codewords
        @blocks.sum(&:affected_total)
      end

      def to_h
        {
          version: @version,
          error_correction_level: @error_correction_level,
          module_count: @module_count,
          reserve_errors: @reserve_errors,
          correctable: correctable?,
          affected_codewords: affected_codewords,
          blocks: @blocks.map(&:to_h),
          function_modules: @function_modules.transform_values do |coords|
            {count: coords.size, modules: coords}
          end,
          remainder_modules: @remainder_modules,
          assumptions: @assumptions
        }
      end
    end

    def self.analyze(qrcode, coordinates, reserve_errors: 0)
      new(qrcode, coordinates, reserve_errors: reserve_errors).report
    end

    def initialize(qrcode, coordinates, reserve_errors: 0)
      @version = qrcode.version
      @module_count = qrcode.module_count
      @error_correction_level = qrcode.error_correction_level
      @coordinates = normalize_coordinates(coordinates)
      @reserve_errors = normalize_reserve_errors(reserve_errors)
    end

    def report
      function_map = build_function_map
      position_index = data_position_index(function_map)
      rs_blocks = QRRSBlock.get_rs_blocks(@version, QRERRORCORRECTLEVEL[@error_correction_level])
      owners = codeword_owners(rs_blocks)

      function_hits = Hash.new { |hash, key| hash[key] = [] }
      remainder_hits = []
      affected = rs_blocks.map { {data: {}, ec: {}} }

      @coordinates.each do |(row, col)|
        category = function_map[row][col]
        if category
          function_hits[category] << [row, col]
          next
        end

        owner = owners[position_index[[row, col]] / 8]
        if owner.nil?
          remainder_hits << [row, col]
        else
          block_index, kind, offset = owner
          affected[block_index][kind][offset] = true
        end
      end

      Report.new(
        version: @version,
        error_correction_level: @error_correction_level,
        module_count: @module_count,
        reserve_errors: @reserve_errors,
        blocks: build_block_reports(rs_blocks, affected),
        function_modules: FUNCTION_CATEGORIES.to_h { |cat| [cat, function_hits[cat].sort] },
        remainder_modules: remainder_hits.sort
      )
    end

    private

    def normalize_coordinates(coordinates)
      valid = coordinates.is_a?(Array) && coordinates.all? do |coord|
        coord.is_a?(Array) && coord.size == 2 && coord.all? { |value| value.is_a?(Integer) }
      end
      unless valid
        raise QRCodeArgumentError, "coordinates must be an Array of [row, column] Integer pairs"
      end

      coordinates.map { |row, col| [row, col] }.uniq.each do |row, col|
        unless row.between?(0, @module_count - 1) && col.between?(0, @module_count - 1)
          raise QRCodeArgumentError, "Invalid row/column pair: #{row}, #{col}"
        end
      end
    end

    def normalize_reserve_errors(reserve_errors)
      unless reserve_errors.is_a?(Integer) && reserve_errors >= 0
        raise QRCodeArgumentError, "reserve_errors must be a non-negative Integer"
      end
      reserve_errors
    end

    def build_block_reports(rs_blocks, affected)
      rs_blocks.each_with_index.map do |rs_block, index|
        BlockReport.new(
          index: index,
          data_count: rs_block.data_count,
          ec_count: rs_block.total_count - rs_block.data_count,
          affected_data_codewords: affected[index][:data].size,
          affected_ec_codewords: affected[index][:ec].size,
          reserved_errors: @reserve_errors
        )
      end
    end

    # Maps every module of the symbol to its function pattern category, or
    # nil when the module carries data. Mirrors the placement order of
    # QRCode (position, alignment, timing, format, version) so overlaps
    # resolve the same way.
    def build_function_map
      map = Array.new(@module_count) { Array.new(@module_count) }
      last = @module_count - 1

      [[0, 0], [@module_count - 7, 0], [0, @module_count - 7]].each do |row, col|
        (-1..7).each do |r|
          (-1..7).each do |c|
            map[row + r][col + c] = :position if (row + r).between?(0, last) && (col + c).between?(0, last)
          end
        end
      end

      positions = QRUtil.get_pattern_positions(@version)
      positions.each do |row|
        positions.each do |col|
          next unless map[row][col].nil?
          (-2..2).each do |r|
            (-2..2).each { |c| map[row + r][col + c] = :alignment }
          end
        end
      end

      (8...@module_count - 8).each do |i|
        map[i][6] = :timing
        map[6][i] = :timing
      end

      QRFORMATINFOLENGTH.times do |i|
        row = (i < 6) ? i : ((i < 8) ? i + 1 : @module_count - 15 + i)
        map[row][8] = :format

        col = (i < 8) ? @module_count - i - 1 : ((i < 9) ? 15 - i : 15 - i - 1)
        map[8][col] = :format
      end
      map[@module_count - 8][8] = :format

      if @version >= 7
        18.times do |i|
          map[(i / 3).floor][i % 3 + @module_count - 8 - 3] = :version
          map[i % 3 + @module_count - 8 - 3][(i / 3).floor] = :version
        end
      end

      map
    end

    # Maps [row, col] => bit position in the final codeword stream by
    # replaying the QRCode data mapping traversal over the modules that
    # carry data. Bit positions beyond the codeword stream are remainder
    # bits and belong to no codeword.
    def data_position_index(function_map)
      index = {}
      bit_position = 0
      inc = -1
      row = @module_count - 1

      (@module_count - 1).step(1, -2) do |col|
        col -= 1 if col <= 6

        loop do
          2.times do |c|
            if function_map[row][col - c].nil?
              index[[row, col - c]] = bit_position
              bit_position += 1
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

      index
    end

    # De-interleaves the final codeword stream: maps each codeword index to
    # [block_index, :data/:ec, offset_within_block], reversing the
    # interleaving performed by QRCode.create_bytes.
    def codeword_owners(rs_blocks)
      data_counts = rs_blocks.map(&:data_count)
      ec_counts = rs_blocks.map { |block| block.total_count - block.data_count }
      owners = []

      data_counts.max.times do |i|
        rs_blocks.each_index do |r|
          owners << [r, :data, i] if i < data_counts[r]
        end
      end

      ec_counts.max.times do |i|
        rs_blocks.each_index do |r|
          owners << [r, :ec, i] if i < ec_counts[r]
        end
      end

      owners
    end
  end
end
