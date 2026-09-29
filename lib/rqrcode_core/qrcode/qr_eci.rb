# frozen_string_literal: true

module RQRCodeCore
  class QREci
    # Common ECI assignment numbers (ISO/IEC 18004 ECI table)
    ECI_ASSIGNMENTS = {
      iso8859_1: 3,
      shift_jis: 20,
      utf8: 26
    }.freeze

    attr_reader :assignment_number

    def initialize(assignment)
      @assignment_number = QREci.resolve(assignment)
    end

    def self.resolve(assignment)
      resolved = assignment.is_a?(Symbol) ? ECI_ASSIGNMENTS[assignment] : assignment
      unless resolved.is_a?(Integer) && resolved.between?(0, 999_999)
        raise QRCodeArgumentError, "Invalid ECI assignment number `#{assignment}`"
      end
      resolved
    end

    # Bits used by the ECI designator for a given assignment number:
    # 8 bits below 128, 16 bits below 16384, 24 bits otherwise.
    def self.designator_bits(assignment)
      resolved = resolve(assignment)
      if resolved < 128
        8
      elsif resolved < 16_384
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
