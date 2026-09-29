# frozen_string_literal: true

module RQRCodeCore
  # Kanji mode encodes double-byte Shift_JIS characters (JIS X 0208) as
  # 13-bit values. Characters that are not representable as double-byte
  # Shift_JIS in the ranges 0x8140-0x9FFC / 0xE040-0xEBBF are rejected.
  class QRKanji
    SHIFT_JIS = Encoding::SHIFT_JIS

    def initialize(data)
      raise QRCodeArgumentError, "Not a kanji string `#{data}`" unless QRKanji.valid_data?(data)

      @data = data
    end

    def self.valid_data?(data)
      data.is_a?(String) && data.each_char.all? { |char| kanji_char?(char) }
    end

    # True when +char+ converts to a double-byte Shift_JIS sequence inside
    # the ranges QR Kanji mode can express.
    def self.kanji_char?(char)
      bytes = char.encode(SHIFT_JIS).bytes
      return false unless bytes.size == 2

      code = (bytes[0] << 8) | bytes[1]
      (0x8140..0x9FFC).cover?(code) || (0xE040..0xEBBF).cover?(code)
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      false
    end

    # 13-bit Kanji mode value for a single character, per ISO/IEC 18004:
    # subtract 0x8140 (or 0xC140), then MSB * 0xC0 + LSB.
    def self.kanji_code(char)
      bytes = char.encode(SHIFT_JIS).bytes
      code = (bytes[0] << 8) | bytes[1]
      code -= (code >= 0xE040) ? 0xC140 : 0x8140
      ((code >> 8) * 0xC0) + (code & 0xFF)
    end

    def write(buffer)
      buffer.kanji_encoding_start(@data.size)

      @data.each_char do |char|
        buffer.put(QRKanji.kanji_code(char), 13)
      end
    end
  end
end
