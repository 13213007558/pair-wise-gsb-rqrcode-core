# frozen_string_literal: true

module RQRCodeCore
  # ECI (Extended Channel Interpretation) segment. Declares the character
  # set of subsequent byte mode segments, e.g. UTF-8 or Shift_JIS.
  class QRECI
    ASSIGNMENTS = {
      iso_8859_1: 3,
      shift_jis: 20,
      utf8: 26
    }.freeze

    attr_reader :assignment_number

    def initialize(assignment_number)
      @assignment_number = Integer(assignment_number)

      unless (0..999_999).cover?(@assignment_number)
        raise QRCodeArgumentError, "Invalid ECI assignment number `#{assignment_number}`"
      end
    end

    # Bits used by the ECI designator for +assignment_number+
    def self.designator_bits(assignment_number)
      number = Integer(assignment_number)
      if number < 128
        8
      elsif number < 16_384
        16
      else
        24
      end
    end

    def write(buffer)
      buffer.eci_encoding_start(@assignment_number)
    end
  end
end
