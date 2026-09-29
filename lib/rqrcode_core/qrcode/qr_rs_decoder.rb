# frozen_string_literal: true

module RQRCodeCore
  # Reed-Solomon decoder over GF(256) for a single QR code block.
  # Corrects both errors (damaged bytes at unknown positions) and
  # erasures (unknown bytes at known positions). A block with +ec_count+
  # error correction codewords can recover from any combination of
  # +e+ errors and +s+ erasures where <tt>2e + s <= ec_count</tt>.
  class QRRSDecoder
    class << self
      # Returns the corrected codeword (data + error correction bytes).
      # Raises QRCodeDecodeError when the block cannot be corrected.
      #
      #   QRRSDecoder.correct(codeword, ec_count, erasures: [3, 7])
      #
      def correct(codeword, ec_count, erasures: [])
        length = codeword.size

        if erasures.any? { |pos| pos < 0 || pos >= length }
          raise QRCodeDecodeError, "Erasure position out of range"
        end

        if erasures.size > ec_count
          raise QRCodeDecodeError,
            "Too many erasures (#{erasures.size}) for #{ec_count} error correction codewords"
        end

        corrected = codeword.dup
        erasures.each { |pos| corrected[pos] = 0 }

        syndromes = calculate_syndromes(corrected, ec_count)
        return corrected if syndromes.all?(&:zero?)

        erasure_locator = errata_locator(erasures, length)
        remaining_syndromes = forney_syndromes(syndromes, erasures, length)
        error_locator = remaining_syndromes.empty? ? [1] : berlekamp_massey(remaining_syndromes)
        error_count = error_locator.size - 1

        if (error_count * 2) + erasures.size > ec_count
          raise QRCodeDecodeError, "Too many errors to correct"
        end

        locator = poly_multiply(error_locator, erasure_locator)
        positions = find_errata_positions(locator, length)

        if positions.size != locator.size - 1
          raise QRCodeDecodeError, "Could not locate all errata"
        end

        evaluator = poly_multiply(syndromes, locator).first(ec_count)
        locator_derivative = poly_derivative(locator)

        positions.each do |pos|
          x = QRMath.gexp(length - 1 - pos)
          x_inv = gf_inverse(x)
          denominator = poly_evaluate(locator_derivative, x_inv)

          if denominator.zero?
            raise QRCodeDecodeError, "Unable to determine errata magnitude"
          end

          magnitude = gf_multiply(x, gf_divide(poly_evaluate(evaluator, x_inv), denominator))
          corrected[pos] ^= magnitude
        end

        unless calculate_syndromes(corrected, ec_count).all?(&:zero?)
          raise QRCodeDecodeError, "Error correction failed"
        end

        corrected
      end

      private

      # Polynomials below are arrays of coefficients, lowest degree first.

      def calculate_syndromes(codeword, ec_count)
        reversed = codeword.reverse
        (0...ec_count).map { |i| poly_evaluate(reversed, QRMath.gexp(i)) }
      end

      def errata_locator(positions, length)
        locator = [1]
        positions.each do |pos|
          locator = poly_multiply(locator, [1, QRMath.gexp(length - 1 - pos)])
        end
        locator
      end

      def forney_syndromes(syndromes, erasures, length)
        result = syndromes.dup
        erasures.each do |pos|
          x = QRMath.gexp(length - 1 - pos)
          (0...(result.size - 1)).each do |i|
            result[i] = gf_multiply(result[i], x) ^ result[i + 1]
          end
          result.pop
        end
        result
      end

      def berlekamp_massey(syndromes)
        locator = [1]
        previous = [1]
        degree = 0
        shift = 1
        base = 1

        syndromes.each_with_index do |syndrome, n|
          discrepancy = syndrome
          (1..degree).each do |i|
            discrepancy ^= gf_multiply(locator[i] || 0, syndromes[n - i])
          end

          if discrepancy.zero?
            shift += 1
          else
            coefficient = gf_divide(discrepancy, base)
            updated = poly_add_scaled(locator, previous, coefficient, shift)

            if 2 * degree <= n
              previous = locator
              base = discrepancy
              degree = n + 1 - degree
              shift = 1
            else
              shift += 1
            end

            locator = updated
          end
        end

        locator.pop while locator.size > 1 && locator.last.zero?
        locator
      end

      def find_errata_positions(locator, length)
        positions = []
        length.times do |pos|
          x_inv = gf_inverse(QRMath.gexp(length - 1 - pos))
          positions << pos if poly_evaluate(locator, x_inv).zero?
        end
        positions
      end

      def poly_derivative(poly)
        (0...poly.size - 1).map { |i| i.even? ? poly[i + 1] : 0 }
      end

      def poly_evaluate(poly, x)
        result = 0
        poly.reverse_each do |coef|
          result = gf_multiply(result, x) ^ coef
        end
        result
      end

      def poly_multiply(a, b)
        result = Array.new(a.size + b.size - 1, 0)
        a.each_with_index do |a_coef, i|
          b.each_with_index do |b_coef, j|
            result[i + j] ^= gf_multiply(a_coef, b_coef)
          end
        end
        result
      end

      def poly_add_scaled(a, b, scale, shift)
        result = Array.new([a.size, b.size + shift].max, 0)
        a.each_with_index { |coef, i| result[i] = coef }
        b.each_with_index { |coef, i| result[i + shift] ^= gf_multiply(scale, coef) }
        result
      end

      def gf_multiply(a, b)
        return 0 if a.zero? || b.zero?

        QRMath.gexp(QRMath.glog(a) + QRMath.glog(b))
      end

      def gf_divide(a, b)
        raise QRCodeDecodeError, "Division by zero during decoding" if b.zero?
        return 0 if a.zero?

        QRMath.gexp(QRMath.glog(a) - QRMath.glog(b))
      end

      def gf_inverse(a)
        gf_divide(1, a)
      end
    end
  end
end
