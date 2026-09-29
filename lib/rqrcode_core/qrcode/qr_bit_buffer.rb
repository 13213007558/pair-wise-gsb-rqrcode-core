# frozen_string_literal: true

module RQRCodeCore
  class QRBitBuffer
    attr_reader :buffer

    PAD0 = 0xEC
    PAD1 = 0x11

    def initialize(version)
      @version = version
      @buffer = []
      @length = 0
    end

    def get(index)
      buf_index = (index / 8).floor
      (QRUtil.rszf(@buffer[buf_index], 7 - index % 8) & 1) == 1
    end

    def put(num, length)
      (0...length).each do |i|
        put_bit((QRUtil.rszf(num, length - i - 1) & 1) == 1)
      end
    end

    def get_length_in_bits
      @length
    end

    def put_bit(bit)
      buf_index = (@length / 8).floor
      if @buffer.size <= buf_index
        @buffer << 0
      end

      if bit
        @buffer[buf_index] |= QRUtil.rszf(0x80, @length % 8)
      end

      @length += 1
    end

    def byte_encoding_start(length)
      put(QRMODE[:mode_8bit_byte], 4)
      put(length, QRUtil.get_length_in_bits(QRMODE[:mode_8bit_byte], @version))
    end

    def alphanumeric_encoding_start(length)
      put(QRMODE[:mode_alpha_numk], 4)
      put(length, QRUtil.get_length_in_bits(QRMODE[:mode_alpha_numk], @version))
    end

    def numeric_encoding_start(length)
      put(QRMODE[:mode_number], 4)
      put(length, QRUtil.get_length_in_bits(QRMODE[:mode_number], @version))
    end

    def kanji_encoding_start(length)
      put(QRMODE[:mode_kanji], 4)
      put(length, QRUtil.get_length_in_bits(QRMODE[:mode_kanji], @version))
    end

    def eci_encoding_start(assignment_number)
      put(QRMODE[:mode_eci], 4)

      if assignment_number < 128
        put(assignment_number, 8)
      elsif assignment_number < 16_384
        put(0b10 << 14 | assignment_number, 16)
      else
        put(0b110 << 21 | assignment_number, 24)
      end
    end

    def pad_until(prefered_size)
      # Align on byte
      while get_length_in_bits % 8 != 0
        put_bit(false)
      end

      # Pad with padding code words
      while get_length_in_bits < prefered_size
        put(PAD0, 8)
        put(PAD1, 8) if get_length_in_bits < prefered_size
      end
    end

    def end_of_message(max_data_bits)
      put(0, 4) unless get_length_in_bits + 4 > max_data_bits
    end
  end
end
