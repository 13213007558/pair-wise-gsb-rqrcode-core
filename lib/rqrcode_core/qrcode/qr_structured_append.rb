# frozen_string_literal: true

module RQRCodeCore
  # Splits data that does not fit into a single QR Code into a series of
  # Structured Append symbols. Each symbol carries a header with its
  # zero-based position, the total symbol count and a shared 8-bit parity
  # (XOR of all bytes of the complete original data).
  #
  #   symbols = RQRCodeCore::QRStructuredAppend.encode("a very long string", level: :h, max_size: 4)
  #   symbols.each { |qr| puts qr.to_s }
  #
  # The split is chosen to first minimise the number of symbols and then the
  # largest version used. Multi-byte characters are never split across
  # symbols. When the data fits into a single symbol within +max_size+, a
  # single plain QR Code (without a Structured Append header) is returned.
  class QRStructuredAppend
    HEADER_BITS = QRSTRUCTUREDAPPENDHEADERBITS
    MAX_SYMBOLS = QRSTRUCTUREDAPPENDMAXSYMBOLS

    # Returns an Array of RQRCodeCore::QRCode symbols encoding +data+
    #
    #   # data - the complete String to encode
    #   # level - the error correction level (:l, :m, :q or :h, default :h)
    #   # max_size - the maximum version (Integer) any single symbol may use
    def self.encode(data, level: :h, max_size: QRUtil.max_size)
      new(data, level: level, max_size: max_size).encode
    end

    def initialize(data, level:, max_size:)
      raise QRCodeArgumentError, "data must be a String" unless data.is_a?(String)

      @level = level.to_sym
      unless QRERRORCORRECTLEVEL.key?(@level)
        raise QRCodeArgumentError, "Unknown error correction level `#{level.inspect}`"
      end

      unless max_size.is_a?(Integer) && max_size.between?(1, QRUtil.max_size)
        raise QRCodeArgumentError, "max_size must be an Integer between 1 and #{QRUtil.max_size}"
      end

      @data = data
      @max_size = max_size
      @characters = data.chars
      @mode = detect_mode
      @byte_offsets = byte_offsets
    end

    def encode
      single_version = minimum_version(@characters.size, header_bits: 0)
      return [QRCode.new(@data, mode: @mode, level: @level, size: single_version)] if single_version

      total = partition(@max_size).size
      if total > MAX_SYMBOLS
        raise QRCodeArgumentError, "Data length exceeds maximum capacity of #{MAX_SYMBOLS} structured append symbols of size #{@max_size}"
      end

      version = (1..@max_size).find { |v| partition(v).size <= total }
      parity = @data.bytes.reduce(0) { |acc, byte| acc ^ byte }

      partition(version).each_with_index.map do |(start, length), index|
        QRCode.new(
          @characters[start, length].join,
          mode: @mode,
          level: @level,
          size: minimum_version(length, offset: start, header_bits: HEADER_BITS),
          structured_append: {position: index, total: total, parity: parity}
        )
      end
    end

    private

    def detect_mode
      if QRNumeric.valid_data?(@data)
        :number
      elsif QRAlphanumeric.valid_data?(@data)
        :alphanumeric
      else
        :byte_8bit
      end
    end

    def byte_offsets
      offsets = [0]
      @characters.each { |char| offsets << offsets.last + char.bytesize }
      offsets
    end

    # Greedily split the data into the fewest chunks that each fit into
    # +version+ (including the Structured Append header). Taking the longest
    # fitting chunk at every step yields the minimal number of chunks.
    def partition(version)
      chunks = []
      start = 0

      while start < @characters.size
        length = max_chunk_length(start, version)
        chunks << [start, length]
        start += length
      end

      chunks
    end

    def max_chunk_length(start, version)
      if chunk_bits(start, 1, version, HEADER_BITS) >= capacity(version)
        raise QRCodeRunTimeError, "A single character does not fit into a version #{version} symbol"
      end

      low = 1
      high = @characters.size - start

      while low < high
        mid = (low + high + 1) / 2
        if chunk_bits(start, mid, version, HEADER_BITS) < capacity(version)
          low = mid
        else
          high = mid - 1
        end
      end

      low
    end

    def minimum_version(length, offset: 0, header_bits: HEADER_BITS)
      (1..@max_size).find do |version|
        chunk_bits(offset, length, version, header_bits) < capacity(version)
      end
    end

    def chunk_bits(offset, length, version, header_bits)
      header_bits + 4 + QRUtil.get_length_in_bits(QRMODE[QRMODE_NAME[@mode]], version) + content_bits(offset, length)
    end

    def content_bits(offset, length)
      case @mode
      when :number
        (length / 3) * QRNumeric::NUMBER_LENGTH[3] + (QRNumeric::NUMBER_LENGTH[length % 3] || 0)
      when :alphanumeric
        (length / 2) * 11 + (length.odd? ? 6 : 0)
      else
        (@byte_offsets[offset + length] - @byte_offsets[offset]) * 8
      end
    end

    def capacity(version)
      QRMAXBITS[@level][version - 1]
    end
  end
end
