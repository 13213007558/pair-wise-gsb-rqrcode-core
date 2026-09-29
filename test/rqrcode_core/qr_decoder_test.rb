require "test_helper"

module RQRCodeCore
  class QRDecoderTest < Minitest::Test
    # Maps each interleaved stream byte to its RS block index
    def stream_byte_blocks(version, level)
      blocks = QRRSBlock.get_rs_blocks(version, QRERRORCORRECTLEVEL[level])
      map = []

      blocks.map(&:data_count).max.times do |i|
        blocks.each_with_index do |block, r|
          map << r if i < block.data_count
        end
      end

      blocks.map { |b| b.total_count - b.data_count }.max.times do |i|
        blocks.each_with_index do |block, r|
          map << r if i < block.total_count - block.data_count
        end
      end

      map
    end

    def flip_stream_bytes!(modules, version, stream_bytes)
      positions = QRDecoder.data_bit_positions(version)
      stream_bytes.each do |byte|
        row, col = positions[byte * 8]
        modules[row][col] = !modules[row][col]
      end
    end

    def erase_stream_bytes!(modules, version, stream_bytes)
      positions = QRDecoder.data_bit_positions(version)
      stream_bytes.each do |byte|
        8.times do |bit|
          row, col = positions[byte * 8 + bit]
          modules[row][col] = nil
        end
      end
    end

    def test_decode_numeric
      qr = RQRCodeCore::QRCode.new("0123456789012345", mode: :number, level: :h)
      result = QRDecoder.decode(qr.modules)

      assert_equal "0123456789012345", result.data
      assert_equal 1, result.segments.size
      assert_equal :number, result.segments.first.mode
      assert_equal "0123456789012345", result.segments.first.data
      assert_equal :h, result.error_correction_level
    end

    def test_decode_alphanumeric
      data = "HELLO WORLD $%*+-./: 123"
      qr = RQRCodeCore::QRCode.new(data, mode: :alphanumeric, level: :m)
      result = QRDecoder.decode(qr.modules)

      assert_equal data, result.data
      assert_equal :alphanumeric, result.segments.first.mode
    end

    def test_decode_byte_8bit
      data = "Hello, World! 123"
      qr = RQRCodeCore::QRCode.new(data, mode: :byte_8bit, level: :q)
      result = QRDecoder.decode(qr.modules)

      assert_equal data, result.data
      assert_equal :byte_8bit, result.segments.first.mode
    end

    def test_decode_utf8_bytes
      data = "こんにちは"
      qr = RQRCodeCore::QRCode.new(data, level: :m)
      result = QRDecoder.decode(qr.modules)

      assert_equal data.b, result.data
      assert_equal data, result.data.dup.force_encoding(Encoding::UTF_8)
    end

    def test_decode_multi_segment
      qr = RQRCodeCore::QRCode.new([
        {data: "12345", mode: :number},
        {data: "ABC DEF", mode: :alphanumeric},
        {data: "hello", mode: :byte_8bit}
      ], level: :q)
      result = QRDecoder.decode(qr.modules)

      assert_equal "12345ABC DEFhello", result.data
      assert_equal [:number, :alphanumeric, :byte_8bit], result.segments.map(&:mode)
      assert_equal ["12345", "ABC DEF", "hello"], result.segments.map(&:data)
    end

    def test_decode_accepts_qrcode_instance
      qr = RQRCodeCore::QRCode.new("INSTANCE", level: :h)
      assert_equal "INSTANCE", QRDecoder.decode(qr).data
      assert_equal "INSTANCE", RQRCodeCore::QRCode.decode(qr).data
    end

    def test_decode_reports_version_and_mask
      qr = RQRCodeCore::QRCode.new("MASK ME", level: :l)
      result = QRDecoder.decode(qr.modules)

      assert_equal qr.version, result.version
      assert_equal :l, result.error_correction_level
      assert_includes (0..7), result.mask_pattern
    end

    def test_decode_all_versions
      (1..40).each do |version|
        data = "B" * (version * 3)
        qr = RQRCodeCore::QRCode.new(data, size: version, level: :m)
        result = QRDecoder.decode(qr.modules)

        assert_equal version, result.version
        assert_equal data, result.data
      end
    end

    def test_decode_version_with_version_information
      data = "V" * 200
      qr = RQRCodeCore::QRCode.new(data, size: 9, level: :m)
      result = QRDecoder.decode(qr.modules)

      assert_equal 9, result.version
      assert_equal data, result.data
    end

    def test_decode_recovers_errors_within_capacity
      # Version 1-H: single block, 17 EC codewords, corrects 8 errors
      data = "ERROR RECOVERY"
      qr = RQRCodeCore::QRCode.new(data, level: :h)
      modules = qr.modules.map(&:dup)
      flip_stream_bytes!(modules, 1, [0, 3, 7, 11, 15, 19, 22, 25])

      assert_equal data, QRDecoder.decode(modules).data
    end

    def test_decode_recovers_erasures_within_capacity
      # Version 1-H: 17 EC codewords recover 17 erasures
      data = "ERASURE"
      qr = RQRCodeCore::QRCode.new(data, level: :h)
      modules = qr.modules.map(&:dup)
      erase_stream_bytes!(modules, 1, (0...17).to_a)

      assert_equal data, QRDecoder.decode(modules).data
    end

    def test_decode_recovers_mixed_errors_and_erasures
      # 2 * 5 errors + 7 erasures = 17 <= 17 EC codewords
      data = "MIXED DAMAGE"
      qr = RQRCodeCore::QRCode.new(data, level: :h)
      modules = qr.modules.map(&:dup)
      flip_stream_bytes!(modules, 1, [20, 21, 22, 24, 25])
      erase_stream_bytes!(modules, 1, (0...7).to_a)

      assert_equal data, QRDecoder.decode(modules).data
    end

    def test_decode_recovers_damage_spread_across_rs_blocks
      # Version 5-Q: 4 blocks of 18 EC codewords each, 9 errors per block
      data = "DAMAGE TEST " * 6
      qr = RQRCodeCore::QRCode.new(data, size: 5, level: :q)
      block_of_byte = stream_byte_blocks(5, :q)
      bytes_per_block = Hash.new { |hash, key| hash[key] = [] }
      block_of_byte.each_with_index { |block, byte| bytes_per_block[block] << byte }

      modules = qr.modules.map(&:dup)
      damaged = bytes_per_block[0].first(9) + bytes_per_block[3].first(9)
      flip_stream_bytes!(modules, 5, damaged)

      assert_equal data, QRDecoder.decode(modules).data
    end

    def test_decode_recovers_erasures_spread_across_rs_blocks
      data = "ERASE SPREAD " * 5
      qr = RQRCodeCore::QRCode.new(data, size: 5, level: :q)
      block_of_byte = stream_byte_blocks(5, :q)
      bytes_per_block = Hash.new { |hash, key| hash[key] = [] }
      block_of_byte.each_with_index { |block, byte| bytes_per_block[block] << byte }

      modules = qr.modules.map(&:dup)
      erased = bytes_per_block[1].first(18) + bytes_per_block[2].first(18)
      erase_stream_bytes!(modules, 5, erased)

      assert_equal data, QRDecoder.decode(modules).data
    end

    def test_decode_fails_beyond_error_capacity
      # 10 errors in one block with only 9 correctable
      data = "DAMAGE TEST " * 6
      qr = RQRCodeCore::QRCode.new(data, size: 5, level: :q)
      block_of_byte = stream_byte_blocks(5, :q)
      block_zero_bytes = block_of_byte.each_index.select { |i| block_of_byte[i] == 0 }

      modules = qr.modules.map(&:dup)
      flip_stream_bytes!(modules, 5, block_zero_bytes.first(10))

      assert_raises(QRCodeDecodeError) { QRDecoder.decode(modules) }
    end

    def test_decode_fails_beyond_erasure_capacity
      # 19 erasures in one block with only 18 recoverable
      data = "DAMAGE TEST " * 6
      qr = RQRCodeCore::QRCode.new(data, size: 5, level: :q)
      block_of_byte = stream_byte_blocks(5, :q)
      block_one_bytes = block_of_byte.each_index.select { |i| block_of_byte[i] == 1 }

      modules = qr.modules.map(&:dup)
      erase_stream_bytes!(modules, 5, block_one_bytes.first(19))

      assert_raises(QRCodeDecodeError) { QRDecoder.decode(modules) }
    end

    def test_decode_fails_on_fully_unknown_matrix
      modules = Array.new(21) { Array.new(21) }
      assert_raises(QRCodeDecodeError) { QRDecoder.decode(modules) }
    end

    def test_decode_tolerates_erased_format_information_copy
      qr = RQRCodeCore::QRCode.new("FORMAT", level: :h)
      modules = qr.modules.map(&:dup)
      QRDecoder.format_info_coordinates(21).first(15).each do |row, col|
        modules[row][col] = nil
      end

      assert_equal "FORMAT", QRDecoder.decode(modules).data
    end

    def test_decode_fails_on_destroyed_format_information
      qr = RQRCodeCore::QRCode.new("FORMAT", level: :h)
      modules = qr.modules.map(&:dup)
      coordinates = QRDecoder.format_info_coordinates(21)
      [0, 1, 2, 3].each do |i|
        modules[coordinates[i][0]][coordinates[i][1]] = !modules[coordinates[i][0]][coordinates[i][1]]
        modules[coordinates[15 + i][0]][coordinates[15 + i][1]] = !modules[coordinates[15 + i][0]][coordinates[15 + i][1]]
      end

      assert_raises(QRCodeDecodeError) { QRDecoder.decode(modules) }
    end

    def test_decode_tolerates_erased_version_information
      data = "V" * 200
      qr = RQRCodeCore::QRCode.new(data, size: 9, level: :m)
      modules = qr.modules.map(&:dup)
      QRDecoder.version_info_coordinates(qr.module_count).each do |row, col|
        modules[row][col] = nil
      end

      assert_equal data, QRDecoder.decode(modules).data
    end

    def test_decode_fails_on_contradictory_version_information
      data = "V" * 200
      qr = RQRCodeCore::QRCode.new(data, size: 9, level: :m)
      modules = qr.modules.map(&:dup)
      bits = QRUtil.get_bch_version(12)
      QRDecoder.version_info_coordinates(qr.module_count).each_with_index do |(row, col), i|
        modules[row][col] = ((bits >> (i % 18)) & 1) == 1
      end

      assert_raises(QRCodeDecodeError) { QRDecoder.decode(modules) }
    end

    def test_decode_rejects_invalid_matrices
      assert_raises(QRCodeArgumentError) { QRDecoder.decode("not a matrix") }
      assert_raises(QRCodeArgumentError) { QRDecoder.decode([[true, false], [false, true]]) }
      assert_raises(QRCodeArgumentError) { QRDecoder.decode(Array.new(21) { Array.new(21, "x") }) }
      assert_raises(QRCodeArgumentError) { QRDecoder.decode(Array.new(21) { Array.new(20, true) }) }
    end

    def test_decode_error_is_a_runtime_error
      assert_kind_of QRCodeRunTimeError, QRCodeDecodeError.new
    end
  end
end
