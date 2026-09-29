# frozen_string_literal: true

module RQRCodeCore
  # Raised when a sampled QR matrix cannot be decoded.
  class QRCodeDecodeError < QRCodeRunTimeError; end

  # Decodes a sampled QR Model 2 symbol matrix back into its payload.
  #
  # The input is a square matrix of modules where each element is
  # +true+ (dark), +false+ (light) or +nil+ (unknown). Unknown modules
  # are treated as erasures and recovered by Reed-Solomon correction
  # together with damaged modules, as long as the damage stays within
  # the correction capacity of the symbol. Inputs that are detectably
  # beyond that capacity raise QRCodeDecodeError; no partial or
  # unverified data is ever returned.
  #
  # Supports the numeric, alphanumeric and byte modes, format/version
  # information recovery, unmasking and codeword deinterleaving.
  #
  #   qr = RQRCodeCore::QRCode.new("HELLO", level: :h)
  #   result = RQRCodeCore::QRDecoder.decode(qr.modules)
  #   result.data    # => "HELLO"
  #   result.segments # => [#<QRDecoder::Segment mode=:alphanumeric, data="HELLO">]
  #
  class QRDecoder
    MODE_INDICATORS = {
      QRMODE[:mode_number] => :number,
      QRMODE[:mode_alpha_numk] => :alphanumeric,
      QRMODE[:mode_8bit_byte] => :byte_8bit
    }.freeze

    MAX_BCH_DISTANCE = 3

    # A single decoded segment of the payload.
    class Segment
      attr_reader :mode, :data

      def initialize(mode, data)
        @mode = mode
        @data = data
      end
    end

    # The result of a successful decode.
    class Result
      attr_reader :version, :error_correction_level, :mask_pattern, :segments, :data, :data_codewords

      def initialize(version:, error_correction_level:, mask_pattern:, segments:, data_codewords:)
        @version = version
        @error_correction_level = error_correction_level
        @mask_pattern = mask_pattern
        @segments = segments
        @data = segments.map(&:data).join
        @data_codewords = data_codewords
      end
    end

    class BitReader
      def initialize(bytes)
        @bytes = bytes
        @position = 0
      end

      def remaining
        @bytes.size * 8 - @position
      end

      def read(length)
        raise QRCodeDecodeError, "Unexpected end of data stream" if length > remaining

        value = 0
        length.times do
          byte = @bytes[@position / 8]
          value = (value << 1) | ((byte >> (7 - (@position % 8))) & 1)
          @position += 1
        end
        value
      end
    end

    class << self
      def decode(input)
        new(input).decode
      end

      # Returns the [row, col] coordinates of every data bit of the
      # given version, in the order bits are read from the matrix
      # (codeword stream order, most significant bit first).
      def data_bit_positions(version, module_count: version * 4 + QRPOSITIONPATTERNLENGTH)
        reserved = function_module_map(version, module_count)
        positions = []
        increment = -1
        row = module_count - 1

        (module_count - 1).step(1, -2) do |col|
          col -= 1 if col <= 6

          loop do
            2.times do |c|
              positions << [row, col - c] unless reserved[row][col - c]
            end

            row += increment

            if row < 0 || module_count <= row
              row -= increment
              increment = -increment
              break
            end
          end
        end

        positions
      end

      # Returns a boolean map marking the function modules (finder,
      # separator, timing, alignment, format/version info, dark module)
      # for the given version. Everything else carries data.
      def function_module_map(version, module_count = version * 4 + QRPOSITIONPATTERNLENGTH)
        map = Array.new(module_count) { Array.new(module_count, false) }
        mark = lambda do |row, col|
          map[row][col] = true if row.between?(0, module_count - 1) && col.between?(0, module_count - 1)
        end

        [[0, 0], [module_count - 7, 0], [0, module_count - 7]].each do |row, col|
          (-1..7).each do |r|
            (-1..7).each { |c| mark.call(row + r, col + c) }
          end
        end

        positions = QRUtil.get_pattern_positions(version)
        positions.each do |row|
          positions.each do |col|
            next if map[row][col]

            (-2..2).each do |r|
              (-2..2).each { |c| mark.call(row + r, col + c) }
            end
          end
        end

        (8...module_count - 8).each do |i|
          map[i][6] = true
          map[6][i] = true
        end

        format_info_coordinates(module_count).each { |row, col| map[row][col] = true }
        map[module_count - 8][8] = true

        if version >= 7
          version_info_coordinates(module_count).each { |row, col| map[row][col] = true }
        end

        map
      end

      def format_info_coordinates(module_count)
        vertical = []
        horizontal = []
        QRFORMATINFOLENGTH.times do |i|
          row = if i < 6
            i
          elsif i < 8
            i + 1
          else
            module_count - 15 + i
          end
          vertical << [row, 8]

          col = if i < 8
            module_count - i - 1
          elsif i < 9
            7
          else
            14 - i
          end
          horizontal << [8, col]
        end
        vertical + horizontal
      end

      def version_info_coordinates(module_count)
        first = []
        second = []
        18.times do |i|
          first << [(i / 3), i % 3 + module_count - 11]
          second << [i % 3 + module_count - 11, (i / 3)]
        end
        first + second
      end
    end

    # Accepts a module matrix (Array of Arrays of true/false/nil) or
    # anything responding to +modules+ (e.g. a QRCode instance).
    def initialize(input)
      matrix = input.respond_to?(:modules) ? input.modules : input

      unless matrix.is_a?(Array) && matrix.all? { |row| row.is_a?(Array) }
        raise QRCodeArgumentError, "Matrix must be an Array of Arrays"
      end

      module_count = matrix.size
      version = (module_count - QRPOSITIONPATTERNLENGTH) / 4

      unless (module_count - QRPOSITIONPATTERNLENGTH) % 4 == 0 &&
          version.between?(1, QRUtil.max_size) &&
          matrix.all? { |row| row.size == module_count }
        raise QRCodeArgumentError, "Matrix must be a square QR module matrix (21x21 to 177x177)"
      end

      unless matrix.all? { |row| row.all? { |cell| cell == true || cell == false || cell.nil? } }
        raise QRCodeArgumentError, "Modules must be true (dark), false (light) or nil (unknown)"
      end

      @matrix = matrix
      @module_count = module_count
      @version = version
    end

    def decode
      level, mask_pattern = decode_format_info
      @error_correct_level = QRERRORCORRECTLEVEL[level]
      verify_version_info if @version >= 7

      codewords, erasures = read_codewords(mask_pattern)
      data_codewords = correct_blocks(codewords, erasures)
      segments = parse_segments(data_codewords)

      Result.new(
        version: @version,
        error_correction_level: level,
        mask_pattern: mask_pattern,
        segments: segments,
        data_codewords: data_codewords
      )
    end

    private

    def decode_format_info
      copies = self.class.format_info_coordinates(@module_count)
        .each_slice(QRFORMATINFOLENGTH)
        .map { |coords| coords.map { |row, col| @matrix[row][col] } }

      data = decode_bch(copies, (0...32).map { |d| [d, QRUtil.get_bch_format_info(d)] })
      raise QRCodeDecodeError, "Unable to decode format information" if data.nil?

      level = QRERRORCORRECTLEVEL.invert[data >> 3]
      [level, data & 7]
    end

    def verify_version_info
      copies = self.class.version_info_coordinates(@module_count)
        .each_slice(18)
        .map { |coords| coords.map { |row, col| @matrix[row][col] } }

      version = decode_bch(copies, (7..QRUtil.max_size).map { |v| [v, QRUtil.get_bch_version(v)] })

      if !version.nil? && version != @version
        raise QRCodeDecodeError,
          "Version information mismatch: matrix size implies version #{@version} but version information decodes to #{version}"
      end
    end

    # Finds the candidate whose BCH codeword is closest to the received
    # bits (unknown bits are skipped). Returns nil when no candidate is
    # within MAX_BCH_DISTANCE or when the best match is ambiguous.
    def decode_bch(copies, candidates)
      best_value = nil
      best_distance = nil
      ambiguous = false

      copies.each do |received|
        next if received.all?(&:nil?)

        candidates.each do |value, expected|
          distance = 0
          received.each_with_index do |bit, i|
            next if bit.nil?

            distance += 1 if bit != (((expected >> i) & 1) == 1)
          end

          if best_distance.nil? || distance < best_distance
            best_distance = distance
            best_value = value
            ambiguous = false
          elsif distance == best_distance && value != best_value
            ambiguous = true
          end
        end
      end

      return nil if best_distance.nil? || best_distance > MAX_BCH_DISTANCE || ambiguous

      best_value
    end

    def read_codewords(mask_pattern)
      rs_blocks = QRRSBlock.get_rs_blocks(@version, @error_correct_level)
      total_count = rs_blocks.sum(&:total_count)
      positions = self.class.data_bit_positions(@version, module_count: @module_count)

      codewords = Array.new(total_count, 0)
      erased = Array.new(total_count, false)

      positions.first(total_count * 8).each_with_index do |(row, col), i|
        byte_index = i / 8
        dark = @matrix[row][col]

        if dark.nil?
          erased[byte_index] = true
        elsif dark ^ QRUtil.get_mask(mask_pattern, row, col)
          codewords[byte_index] |= 1 << (7 - (i % 8))
        end
      end

      erasures = []
      erased.each_with_index { |flag, i| erasures << i if flag }
      [codewords, erasures]
    end

    def correct_blocks(codewords, erasures)
      rs_blocks = QRRSBlock.get_rs_blocks(@version, @error_correct_level)
      erased = Array.new(codewords.size, false)
      erasures.each { |i| erased[i] = true }

      blocks = rs_blocks.map do |block|
        ec_count = block.total_count - block.data_count
        {data: Array.new(block.data_count), ec: Array.new(ec_count), erasures: []}
      end

      index = 0
      max_data_count = rs_blocks.map(&:data_count).max
      max_ec_count = rs_blocks.map { |block| block.total_count - block.data_count }.max

      max_data_count.times do |i|
        rs_blocks.each_with_index do |block, r|
          next if i >= block.data_count

          blocks[r][:data][i] = codewords[index]
          blocks[r][:erasures] << i if erased[index]
          index += 1
        end
      end

      max_ec_count.times do |i|
        rs_blocks.each_with_index do |block, r|
          ec_count = block.total_count - block.data_count
          next if i >= ec_count

          blocks[r][:ec][i] = codewords[index]
          blocks[r][:erasures] << (block.data_count + i) if erased[index]
          index += 1
        end
      end

      data_codewords = []
      rs_blocks.each_with_index do |block, r|
        ec_count = block.total_count - block.data_count
        corrected = QRRSDecoder.correct(blocks[r][:data] + blocks[r][:ec], ec_count, erasures: blocks[r][:erasures])
        data_codewords.concat(corrected.first(block.data_count))
      end
      data_codewords
    end

    def parse_segments(data_codewords)
      reader = BitReader.new(data_codewords)
      segments = []

      loop do
        break if reader.remaining < 4

        indicator = reader.read(4)
        break if indicator.zero?

        mode = MODE_INDICATORS[indicator]
        raise QRCodeDecodeError, "Unsupported mode indicator: #{indicator.to_s(2)}" if mode.nil?

        count = reader.read(QRUtil.get_length_in_bits(indicator, @version))
        segments << Segment.new(mode, read_segment_data(reader, mode, count))
      end

      segments
    end

    def read_segment_data(reader, mode, count)
      case mode
      when :number
        read_numeric_data(reader, count)
      when :alphanumeric
        read_alphanumeric_data(reader, count)
      else
        Array.new(count) { reader.read(8) }.pack("C*")
      end
    end

    def read_numeric_data(reader, count)
      data = +""

      while count >= 3
        value = reader.read(10)
        raise QRCodeDecodeError, "Invalid numeric group: #{value}" if value > 999

        data << value.to_s.rjust(3, "0")
        count -= 3
      end

      if count == 2
        value = reader.read(7)
        raise QRCodeDecodeError, "Invalid numeric group: #{value}" if value > 99

        data << value.to_s.rjust(2, "0")
      elsif count == 1
        value = reader.read(4)
        raise QRCodeDecodeError, "Invalid numeric group: #{value}" if value > 9

        data << value.to_s
      end

      data
    end

    def read_alphanumeric_data(reader, count)
      data = +""

      while count >= 2
        value = reader.read(11)
        raise QRCodeDecodeError, "Invalid alphanumeric pair: #{value}" if value >= 45 * 45

        data << ALPHANUMERIC[value / 45] << ALPHANUMERIC[value % 45]
        count -= 2
      end

      if count == 1
        value = reader.read(6)
        raise QRCodeDecodeError, "Invalid alphanumeric value: #{value}" if value >= 45

        data << ALPHANUMERIC[value]
      end

      data
    end
  end

  class QRCode
    # Decodes a sampled module matrix (or QRCode) back into its payload.
    # See QRDecoder.
    def self.decode(input)
      QRDecoder.decode(input)
    end
  end
end
