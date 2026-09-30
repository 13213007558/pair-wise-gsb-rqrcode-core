# frozen_string_literal: true

require "test_helper"

module RQRCodeCore
  class OverlayAnalysisTest < Minitest::Test
    # Version 1-H: single RS block (26 total, 9 data, 17 ec), module_count 21.
    # First data codeword occupies rows 17..20, cols 19..20 (bottom-right).
    FIRST_DATA_CODEWORD = [[20, 20], [20, 19], [19, 20], [19, 19], [18, 20], [18, 19], [17, 20], [17, 19]].freeze
    # First ec codeword (byte 9) occupies rows 17..20, cols 13..14.
    FIRST_EC_CODEWORD = [[20, 14], [20, 13], [19, 14], [19, 13], [18, 14], [18, 13], [17, 14], [17, 13]].freeze

    def setup
      @qr = RQRCodeCore::QRCode.new("hello", size: 1, level: :h)
    end

    def test_counts_codeword_once_when_multiple_modules_covered
      report = @qr.analyze_overlay(FIRST_DATA_CODEWORD)

      assert_equal 1, report.blocks.size
      block = report.blocks.first
      assert_equal 1, block.affected_data_codewords
      assert_equal 0, block.affected_ec_codewords
      assert_equal 1, block.affected_total
      assert_equal 17 - 1, block.remaining_margin
      assert_predicate block, :correctable?
    end

    def test_partial_coverage_counts_same_as_full_coverage
      partial = @qr.analyze_overlay(FIRST_DATA_CODEWORD.first(3))
      full = @qr.analyze_overlay(FIRST_DATA_CODEWORD)

      assert_equal full.blocks.first.affected_total, partial.blocks.first.affected_total
    end

    def test_data_and_ec_codewords_tracked_separately
      report = @qr.analyze_overlay(FIRST_DATA_CODEWORD + FIRST_EC_CODEWORD)
      block = report.blocks.first

      assert_equal 1, block.affected_data_codewords
      assert_equal 1, block.affected_ec_codewords
      assert_equal 2, block.affected_total
    end

    def test_deinterleaves_codewords_across_rs_blocks
      # Version 5-H has 4 RS blocks (2x 33/11, 2x 34/12, 22 ec each).
      # A 2-wide strip at the right edge hits interleaved data codewords
      # 0, 1 and 2, which belong to blocks 0, 1 and 2 respectively.
      qr = RQRCodeCore::QRCode.new("cross block check", size: 5, level: :h)
      strip = (28..36).flat_map { |row| [[row, 36], [row, 35]] }
      report = qr.analyze_overlay(strip)

      assert_equal 4, report.blocks.size
      assert_equal [1, 1, 1, 0], report.blocks.map(&:affected_data_codewords)
      assert_equal [1, 1, 1, 0], report.blocks.map(&:affected_total)
      assert_equal [21, 21, 21, 22], report.blocks.map(&:remaining_margin)
    end

    def test_function_modules_reported_separately
      report = @qr.analyze_overlay([[0, 0], [6, 8], [8, 0], [20, 8]])

      assert_equal [[0, 0]], report.function_modules[:position]
      assert_equal [[6, 8]], report.function_modules[:timing]
      assert_equal [[8, 0], [20, 8]], report.function_modules[:format]
      assert_empty report.function_modules[:alignment]
      assert_empty report.function_modules[:version]
      assert_equal 0, report.affected_codewords
      assert_equal 17, report.blocks.first.remaining_margin
    end

    def test_version_info_modules_reported_separately
      qr = RQRCodeCore::QRCode.new("version seven", size: 7, level: :l)
      report = qr.analyze_overlay([[0, 34], [34, 0]])

      assert_equal [[0, 34], [34, 0]], report.function_modules[:version]
      assert_equal 0, report.affected_codewords
    end

    def test_remainder_modules_do_not_consume_ec_budget
      # Version 2-L: one block (44 total, 34 data, 10 ec) and 7 remainder bits.
      qr = RQRCodeCore::QRCode.new("remainder", size: 2, level: :l)
      all_modules = (0...25).flat_map { |row| (0...25).map { |col| [row, col] } }
      report = qr.analyze_overlay(all_modules)

      assert_equal 7, report.remainder_modules.size
      assert_equal 34, report.blocks.first.affected_data_codewords
      assert_equal 10, report.blocks.first.affected_ec_codewords
      assert_equal 192, report.function_modules[:position].size
      assert_equal 18, report.function_modules[:timing].size
      assert_equal 25, report.function_modules[:alignment].size
      assert_equal 31, report.function_modules[:format].size
      assert_equal 0, report.function_modules[:version].size
    end

    def test_reserve_errors_reduce_remaining_margin
      report = @qr.analyze_overlay(FIRST_DATA_CODEWORD, reserve_errors: 2)
      assert_equal 17 - 1 - 4, report.blocks.first.remaining_margin
      assert_predicate report, :correctable?

      report = @qr.analyze_overlay(FIRST_DATA_CODEWORD, reserve_errors: 9)
      assert_equal 17 - 1 - 18, report.blocks.first.remaining_margin
      refute_predicate report, :correctable?
    end

    def test_report_includes_assumptions_and_to_h
      report = @qr.analyze_overlay(FIRST_DATA_CODEWORD, reserve_errors: 1)
      hash = report.to_h

      assert_equal 1, hash[:version]
      assert_equal :h, hash[:error_correction_level]
      assert_equal 1, hash[:reserve_errors]
      assert_equal 1, hash[:affected_codewords]
      assert_equal 1, hash[:blocks].first[:affected_total]
      assert_includes hash[:function_modules].keys, :position
      assert hash[:assumptions].any? { |note| note.include?("conservative bound") }
      assert_same report.assumptions, RQRCodeCore::QROverlayAnalysis::ASSUMPTIONS
    end

    def test_duplicate_coordinates_count_once
      report = @qr.analyze_overlay([[0, 0], [0, 0]] + FIRST_DATA_CODEWORD + [FIRST_DATA_CODEWORD.first])

      assert_equal [[0, 0]], report.function_modules[:position]
      assert_equal 1, report.blocks.first.affected_total
    end

    def test_does_not_modify_qrcode
      before = @qr.modules.map(&:dup)
      rendered_before = @qr.to_s

      @qr.analyze_overlay(FIRST_DATA_CODEWORD + [[0, 0], [8, 8]], reserve_errors: 3)

      assert_equal before, @qr.modules
      assert_equal rendered_before, @qr.to_s
    end

    def test_invalid_coordinates_raise_argument_error
      assert_raises(RQRCodeCore::QRCodeArgumentError) { @qr.analyze_overlay("nope") }
      assert_raises(RQRCodeCore::QRCodeArgumentError) { @qr.analyze_overlay([[0]]) }
      assert_raises(RQRCodeCore::QRCodeArgumentError) { @qr.analyze_overlay([["0", 0]]) }
      assert_raises(RQRCodeCore::QRCodeArgumentError) { @qr.analyze_overlay([[-1, 0]]) }
      assert_raises(RQRCodeCore::QRCodeArgumentError) { @qr.analyze_overlay([[0, 21]]) }
    end

    def test_invalid_reserve_errors_raise_argument_error
      assert_raises(RQRCodeCore::QRCodeArgumentError) { @qr.analyze_overlay([], reserve_errors: -1) }
      assert_raises(RQRCodeCore::QRCodeArgumentError) { @qr.analyze_overlay([], reserve_errors: 1.5) }
    end

    def test_class_level_entry_point
      report = RQRCodeCore::QROverlayAnalysis.analyze(@qr, FIRST_DATA_CODEWORD)

      assert_instance_of RQRCodeCore::QROverlayAnalysis::Report, report
      assert_equal 1, report.affected_codewords
    end
  end
end
