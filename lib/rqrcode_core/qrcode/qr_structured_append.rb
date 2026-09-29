# frozen_string_literal: true

module RQRCodeCore
  # Structured Append (ISO/IEC 18004) support.
  #
  # When a message does not fit into a single symbol of a given maximum
  # version, the message is split across up to MAX_SYMBOLS linked symbols.
  # Every symbol carries a Structured Append header (mode indicator 0011,
  # symbol position, total symbol count and a shared parity byte) directly
  # in its bit stream, and the header bits are accounted for when the
  # capacity of each symbol is computed.
  #
  #   sa = RQRCodeCore::QRStructuredAppend.new(data, level: :h, max_size: 4)
  #   sa.symbols  # => Array of RQRCodeCore::QRCode
  #   sa.chunks   # => the data slice carried by each symbol
  #   sa.parity   # => XOR of all bytes of the original data
  #
  # When the data fits in a single symbol within max_size, a single plain
  # QRCode (without Structured Append header) is returned.
  class QRStructuredAppend
    MAX_SYMBOLS = 16
    MODE_INDICATOR = 0b0011
    # mode indicator (4) + position (4) + total (4) + parity (8)
    HEADER_BITS = 20

    NUMERIC_EXTRA_BITS = {0 => 0, 1 => 4, 2 => 7}.freeze

    # Bit stream writer that prefixes a segment with the Structured Append
    # header: mode indicator 0011, 4-bit symbol position, 4-bit total symbol
    # count minus one and the 8-bit parity of the whole message.
    class Writer
      def initialize(position:, total:, parity:, data_writer:)
        @position = position
        @total = total
        @parity = parity
        @data_writer = data_writer
      end

      def write(buffer)
        buffer.put(QRStructuredAppend::MODE_INDICATOR, 4)
        buffer.put(@position, 4)
        buffer.put(@total - 1, 4)
        buffer.put(@parity, 8)
        @data_writer.write(buffer)
      end
    end

    attr_reader :data, :level, :max_size, :symbols, :chunks, :parity

    def initialize(data, level: :h, max_size: QRUtil.max_size)
      raise QRCodeArgumentError, "data must be a String" unless data.is_a?(String)

      @level = level.to_sym
      unless QRERRORCORRECTLEVEL.key?(@level)
        raise QRCodeArgumentError, "Unknown error correction level `#{level.inspect}`"
      end

      unless max_size.is_a?(Integer) && max_size.between?(1, QRUtil.max_size)
        raise QRCodeArgumentError, "max_size must be an Integer between 1 and #{QRUtil.max_size}"
      end
      @max_size = max_size

      @data = data
      @parity = self.class.compute_parity(data)
      prepare_prefixes
      @chunks, @versions = plan
      @symbols = build_symbols
    end

    # Number of symbols the message was split into
    def count
      @symbols.size
    end

    # True when the message did not fit in a single symbol
    def structured_append?
      count > 1
    end

    # Parity is the byte-wise XOR of all bytes of the original message
    def self.compute_parity(data)
      data.bytes.reduce(0) { |acc, byte| acc ^ byte }
    end

    private

    def prepare_prefixes
      @chars = @data.each_char.to_a
      @char_count = @chars.size
      @byte_prefix = [0]
      @digit_prefix = [0]
      @alnum_prefix = [0]
      @chars.each do |char|
        @byte_prefix << @byte_prefix.last + char.bytesize
        @digit_prefix << @digit_prefix.last + (QRNumeric.valid_data?(char) ? 1 : 0)
        @alnum_prefix << @alnum_prefix.last + (QRAlphanumeric.valid_data?(char) ? 1 : 0)
      end
    end

    def plan
      single_version = chunk_minimum_version(0, @char_count, 0)
      return [[@data], [single_version]] if single_version

      max_partition = partition(@max_size)
      count = max_partition&.size
      if count.nil? || count > MAX_SYMBOLS
        raise QRCodeArgumentError, "Data does not fit in #{MAX_SYMBOLS} symbols of version #{@max_size} or smaller"
      end

      # Fewest symbols first, then minimize the largest version used.
      best_version = (1..@max_size).bsearch do |version|
        candidate = partition(version)
        !candidate.nil? && candidate.size <= count
      end
      chunks = partition(best_version)

      versions = []
      from = 0
      chunks.each do |chunk|
        versions << chunk_minimum_version(from, from + chunk.length, HEADER_BITS)
        from += chunk.length
      end
      [chunks, versions]
    end

    # Splits the message into the fewest possible chunks such that every
    # chunk (including its Structured Append header) fits in the given
    # version. Chunks are filled from the start as much as possible, which
    # keeps the result deterministic and never breaks a multi-byte
    # character. Returns nil when a single character does not fit.
    def partition(capacity)
      chunks = []
      from = 0
      while from < @char_count
        to = from
        (from + 1).upto(@char_count) do |candidate|
          version = chunk_minimum_version(from, candidate, HEADER_BITS)
          break if version.nil? || version > capacity
          to = candidate
        end
        return nil if to == from
        chunks << @chars[from...to].join
        from = to
      end
      chunks
    end

    # Smallest version (up to max_size) whose capacity strictly exceeds the
    # given header bits plus the segment bits of the character range.
    def chunk_minimum_version(from, to, header_bits)
      length = to - from
      if @digit_prefix[to] - @digit_prefix[from] == length
        mode = QRMODE[:mode_number]
        content_bits = (length / 3) * 10 + NUMERIC_EXTRA_BITS[length % 3]
      elsif @alnum_prefix[to] - @alnum_prefix[from] == length
        mode = QRMODE[:mode_alpha_numk]
        content_bits = (length / 2) * 11 + (length % 2) * 6
      else
        mode = QRMODE[:mode_8bit_byte]
        content_bits = (@byte_prefix[to] - @byte_prefix[from]) * 8
      end

      version = 1
      while version <= @max_size
        size_bits = header_bits + 4 + QRUtil.get_length_in_bits(mode, version) + content_bits
        return version if size_bits < QRMAXBITS[@level][version - 1]
        version += 1
      end
      nil
    end

    def build_symbols
      total = @chunks.size
      if total == 1
        [QRCode.new(@data, level: @level)]
      else
        @chunks.each_with_index.map do |chunk, index|
          QRCode.new(chunk, level: @level, size: @versions[index],
            structured_append: {position: index, total: total, parity: @parity})
        end
      end
    end
  end
end
