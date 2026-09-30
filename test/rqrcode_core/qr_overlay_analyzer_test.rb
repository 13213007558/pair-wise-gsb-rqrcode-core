require "test_helper"

module RQRCodeCore
  class QROverlayAnalyzerTest < Minitest::Test
    def test_multiple_modules_of_same_codeword_count_once
      qr = QRCode.new("HELLO", size: 1, level: :h)
      analyzer = QROverlayAnalyzer.new(qr)
      positions = analyzer.codeword_positions(0)

      assert_equal 8, positions.size

      report = analyzer.analyze(positions.first(3))

      assert_equal 1, report[:affected_codewords]
      assert_equal 1, report[:blocks].size
      assert_equal 1, report[:blocks][0][:affected_data_codewords]
      assert_equal 0, report[:blocks][0][:affected_ec_codewords]
      assert_equal 1, report[:blocks][0][:affected_codewords]
    end

    def test_covering_all_8_modules_of_a_codeword_still_counts_once
      qr = QRCode.new("HELLO", size: 1, level: :h)
      analyzer = QROverlayAnalyzer.new(qr)

      report = analyzer.analyze(analyzer.codeword_positions(0))

      assert_equal 8, report[:covered_module_count]
      assert_equal 1, report[:affected_codewords]
    end

    def test_occlusion_spanning_multiple_blocks
      # version 5, level q => 4 RS blocks: 2x(33, 15) + 2x(34, 16)
      qr = QRCode.new("OCCLUSION", size: 5, level: :q)
      analyzer = QROverlayAnalyzer.new(qr)

      coords = analyzer.codeword_positions(0) + analyzer.codeword_positions(1)
      report = analyzer.analyze(coords)

      assert_equal 4, report[:blocks].size
      assert_equal 1, report[:blocks][0][:affected_codewords]
      assert_equal 1, report[:blocks][1][:affected_codewords]
      assert_equal 0, report[:blocks][2][:affected_codewords]
      assert_equal 0, report[:blocks][3][:affected_codewords]
    end

    def test_interleaved_codewords_map_back_to_correct_block
      # version 5, level q => data codewords interleaved across 4 blocks,
      # then ec codewords interleaved across 4 blocks
      qr = QRCode.new("OCCLUSION", size: 5, level: :q)
      analyzer = QROverlayAnalyzer.new(qr)

      assert_equal [0, :data, 0], analyzer.codeword_location(0)
      assert_equal [1, :data, 0], analyzer.codeword_location(1)
      assert_equal [2, :data, 0], analyzer.codeword_location(2)
      assert_equal [3, :data, 0], analyzer.codeword_location(3)
      # long blocks own the two extra trailing data codewords
      assert_equal [2, :data, 15], analyzer.codeword_location(60)
      assert_equal [3, :data, 15], analyzer.codeword_location(61)
      # first ec codeword of the ec section belongs to block 0
      assert_equal [0, :ec, 0], analyzer.codeword_location(62)
      assert_equal [3, :ec, 17], analyzer.codeword_location(133)
    end

    def test_ec_codewords_attributed_to_correct_block
      qr = QRCode.new("OCCLUSION", size: 5, level: :q)
      analyzer = QROverlayAnalyzer.new(qr)

      report = analyzer.analyze(analyzer.codeword_positions(62))

      assert_equal 0, report[:blocks][0][:affected_data_codewords]
      assert_equal 1, report[:blocks][0][:affected_ec_codewords]
      assert(report[:blocks][1..].all? { |block| block[:affected_codewords] == 0 })
    end

    def test_function_modules_reported_separately
      qr = QRCode.new("HELLO WORLD", size: 2, level: :m)
      module_count = qr.module_count
      coords = [
        [0, 0], # finder
        [7, 7], # finder (separator ring)
        [6, 10], # timing
        [18, 18], # alignment
        [8, 1], # format info
        [module_count - 8, 8] # dark module
      ]

      report = QROverlayAnalyzer.analyze(qr, coords)

      assert_equal 0, report[:affected_codewords]
      assert(report[:blocks].all? { |block| block[:affected_codewords] == 0 })
      assert_equal [[0, 0], [7, 7]], report[:function_modules][:finder][:coordinates]
      assert_equal 2, report[:function_modules][:finder][:count]
      assert_equal [[6, 10]], report[:function_modules][:timing][:coordinates]
      assert_equal [[18, 18]], report[:function_modules][:alignment][:coordinates]
      assert_equal [[8, 1]], report[:function_modules][:format_info][:coordinates]
      assert_equal [[module_count - 8, 8]], report[:function_modules][:dark_module][:coordinates]
      assert_equal 0, report[:function_modules][:version_info][:count]
    end

    def test_version_info_reported_separately
      qr = QRCode.new("HELLO WORLD", size: 7, level: :m)

      report = QROverlayAnalyzer.analyze(qr, [[0, qr.module_count - 11], [qr.module_count - 11, 0]])

      assert_equal 2, report[:function_modules][:version_info][:count]
      assert_equal 0, report[:affected_codewords]
    end

    def test_remainder_bits_reported_separately
      qr = QRCode.new("HELLO", size: 2, level: :m)
      analyzer = QROverlayAnalyzer.new(qr)
      remainder = analyzer.remainder_positions

      assert_equal 7, remainder.size

      report = analyzer.analyze(remainder)

      assert_equal 7, report[:remainder_bits_covered]
      assert_equal 0, report[:affected_codewords]
      assert(report[:blocks].all? { |block| block[:affected_codewords] == 0 })
    end

    def test_reserved_errors_reduce_remaining_margin
      # version 1, level h => single block, 26 total, 9 data, 17 ec
      qr = QRCode.new("HELLO", size: 1, level: :h)
      analyzer = QROverlayAnalyzer.new(qr)

      report = analyzer.analyze(analyzer.codeword_positions(0), reserved_errors: 2)
      block = report[:blocks][0]

      assert_equal 17, block[:ec_count]
      assert_equal 17, block[:erasure_capacity]
      assert_equal 2, block[:reserved_errors]
      assert_equal 17 - (2 * 2) - 1, block[:remaining_margin]
      assert block[:recoverable]
      assert report[:recoverable]
    end

    def test_unrecoverable_when_margin_exceeded
      qr = QRCode.new("HELLO", size: 1, level: :h)
      analyzer = QROverlayAnalyzer.new(qr)

      report = analyzer.analyze(analyzer.codeword_positions(0), reserved_errors: 9)

      refute report[:blocks][0][:recoverable]
      refute report[:recoverable]
      assert_operator report[:blocks][0][:remaining_margin], :<, 0
    end

    def test_duplicate_coordinates_counted_once
      qr = QRCode.new("HELLO", size: 1, level: :h)
      analyzer = QROverlayAnalyzer.new(qr)
      positions = analyzer.codeword_positions(0).first(2)

      report = analyzer.analyze(positions + positions.reverse)

      assert_equal 2, report[:covered_module_count]
      assert_equal 1, report[:affected_codewords]
    end

    def test_empty_coordinates
      qr = QRCode.new("HELLO", size: 1, level: :h)

      report = QROverlayAnalyzer.analyze(qr, [])

      assert_equal 0, report[:covered_module_count]
      assert_equal 0, report[:affected_codewords]
      assert report[:recoverable]
    end

    def test_invalid_coordinates_raise
      qr = QRCode.new("HELLO", size: 1)

      assert_raises(QRCodeArgumentError) { QROverlayAnalyzer.analyze(qr, [[0, 21]]) }
      assert_raises(QRCodeArgumentError) { QROverlayAnalyzer.analyze(qr, [[-1, 0]]) }
      assert_raises(QRCodeArgumentError) { QROverlayAnalyzer.analyze(qr, [[1]]) }
      assert_raises(QRCodeArgumentError) { QROverlayAnalyzer.analyze(qr, [["1", 0]]) }
      assert_raises(QRCodeArgumentError) { QROverlayAnalyzer.analyze(qr, nil) }
      assert_raises(QRCodeArgumentError) { QROverlayAnalyzer.analyze(qr, [], reserved_errors: -1) }
      assert_raises(QRCodeArgumentError) { QROverlayAnalyzer.analyze(qr, [], reserved_errors: 1.5) }
    end

    def test_analysis_does_not_modify_qr_code
      qr = QRCode.new("HELLO WORLD", size: 2, level: :q)
      modules_before = qr.modules.map(&:dup)
      rendering_before = qr.to_s

      analyzer = QROverlayAnalyzer.new(qr)
      analyzer.analyze(analyzer.codeword_positions(0) + [[0, 0], [8, 8]], reserved_errors: 1)
      qr.overlay_analysis([[1, 1]])

      assert_equal modules_before, qr.modules
      assert_equal rendering_before, qr.to_s
    end

    def test_qr_code_overlay_analysis_convenience_method
      qr = QRCode.new("HELLO", size: 1, level: :h)
      analyzer = QROverlayAnalyzer.new(qr)

      report = qr.overlay_analysis(analyzer.codeword_positions(0))

      assert_equal 1, report[:version]
      assert_equal :h, report[:error_correction_level]
      assert_equal 1, report[:affected_codewords]
      assert_kind_of Array, report[:assumptions]
      assert(report[:assumptions].any? { |a| a.include?("conservative bound") })
    end

    def test_cell_map_consistent_across_versions
      [1, 2, 5, 6, 7, 10, 14, 21, 28, 35, 40].each do |version|
        qr = QRCode.new("CONSISTENCY", size: version, level: :m)
        analyzer = QROverlayAnalyzer.new(qr)

        total_codewords = QRRSBlock.get_rs_blocks(version, QRERRORCORRECTLEVEL[:m]).sum(&:total_count)
        assert_equal 8, analyzer.codeword_positions(0).size, "version #{version}"
        assert_equal 8, analyzer.codeword_positions(total_codewords - 1).size, "version #{version}"
        assert_equal QROverlayAnalyzer::REMAINDER_BITS[version - 1], analyzer.remainder_positions.size, "version #{version}"
      end
    end

    def test_unknown_codeword_index_raises
      qr = QRCode.new("HELLO", size: 1, level: :h)
      analyzer = QROverlayAnalyzer.new(qr)

      assert_raises(QRCodeArgumentError) { analyzer.codeword_positions(26) }
      assert_raises(QRCodeArgumentError) { analyzer.codeword_location(-1) }
    end
  end
end
