# frozen_string_literal: true

module RQRCodeCore
  class QRKanji
    # Shift_JIS double-byte ranges accepted by the QR kanji mode
    # (ISO/IEC 18004): 0x8140-0x9FFC and 0xE040-0xEBBF.
    KANJI_RANGES = [(0x8140..0x9FFC), (0xE040..0xEBBF)].freeze

    def initialize(data)
      raise QRCodeArgumentError, "Not a valid kanji string `#{data}`" unless QRKanji.valid_data?(data)

      @data = data
    end

    def self.valid_data?(data)
      data.each_char.all? { |char| !kanji_code(char).nil? }
    end

    # 13-bit QR kanji code for a single character, or nil when the
    # character is not a Shift_JIS double-byte character. The conversion
    # goes through Ruby's Shift_JIS encoder so only genuinely encodable
    # characters are accepted.
    def self.kanji_code(char)
      sjis = char.encode(Encoding::Shift_JIS)
      return nil unless sjis.bytesize == 2

      value = sjis.unpack1("S>")
      subtracted = if KANJI_RANGES[0].cover?(value)
        value - 0x8140
      elsif KANJI_RANGES[1].cover?(value)
        value - 0xC140
      else
        return nil
      end

      ((subtracted >> 8) * 0xC0) + (subtracted & 0xFF)
    rescue EncodingError
      nil
    end

    def write(buffer)
      buffer.kanji_encoding_start(@data.size)

      @data.each_char do |char|
        buffer.put(QRKanji.kanji_code(char), 13)
      end
    end
  end
end
