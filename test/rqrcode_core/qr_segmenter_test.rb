# frozen_string_literal: true

require "test_helper"

class RQRCodeCore::QRSegmenterTest < Minitest::Test
  include RQRCodeCore

  GROUP_VERSION = [1, 10, 27].freeze

  # Characters covering every mode category: numeric only, alphanumeric
  # only, byte only, kanji (also Shift_JIS double-byte) and halfwidth
  # katakana (Shift_JIS single-byte only).
  ALPHABET = ["1", "A", "a", "漢", "ｱ"].freeze

  def segment_bits(segments, version)
    segments.sum { |seg| QRSegment.new(**seg).size(version) }
  end

  def mode_options_for(run)
    options = []
    options << {data: run, mode: :number} if run.each_char.all? { |c| QRNumeric.valid_data?(c) }
    options << {data: run, mode: :alphanumeric} if run.each_char.all? { |c| QRAlphanumeric.valid_data?(c) }
    options << {data: run, mode: :kanji} if QRKanji.valid_data?(run)
    options << {data: run, mode: :byte_8bit, eci: :none}
    options << {data: run.encode(Encoding::UTF_8), mode: :byte_8bit, eci: :utf8}
    begin
      options << {data: run.encode(Encoding::Shift_JIS), mode: :byte_8bit, eci: :shift_jis}
    rescue EncodingError
      # run not representable in Shift_JIS
    end
    options
  end

  # Exhaustively enumerates every legal segmentation of the string (all
  # cut positions, all valid modes per run, all ECI contexts for byte
  # runs) and returns the minimal bit count for the given version.
  def brute_force_minimum_bits(string, version)
    chars = string.chars
    return 0 if chars.empty?

    best = Float::INFINITY
    (0...(1 << (chars.length - 1))).each do |mask|
      runs = []
      run = +""
      chars.each_with_index do |char, i|
        if i > 0 && mask[i - 1] == 1
          runs << run
          run = +""
        end
        run << char
      end
      runs << run

      option_lists = runs.map { |r| mode_options_for(r) }
      option_lists.first.each do |first|
        enumerate_options(option_lists, 1, [first]) do |choice|
          bits = bits_with_eci_switches(choice, version)
          best = bits if bits < best
        end
      end
    end
    best
  end

  def enumerate_options(option_lists, index, choice, &block)
    return yield(choice) if index == option_lists.length

    option_lists[index].each do |option|
      enumerate_options(option_lists, index + 1, choice + [option], &block)
    end
  end

  ECI_ASSIGNMENT = {utf8: 26, shift_jis: 20}.freeze

  def bits_with_eci_switches(choice, version)
    current_eci = :none
    segments = []
    choice.each do |option|
      if option[:mode] == :byte_8bit && option[:eci] != current_eci
        # the :none context has no ECI designator and cannot be re-entered
        return Float::INFINITY if option[:eci] == :none

        segments << {data: ECI_ASSIGNMENT[option[:eci]], mode: :eci}
        current_eci = option[:eci]
      end
      segments << option.slice(:data, :mode)
    end
    segment_bits(segments, version)
  end

  def test_simple_segment_choices
    assert_equal [{data: "123", mode: :number}], QRSegmenter.segment("123")
    assert_equal [{data: "ABC", mode: :alphanumeric}], QRSegmenter.segment("ABC")
    assert_equal [{data: "abc", mode: :byte_8bit}], QRSegmenter.segment("abc")
    assert_equal [{data: "漢字", mode: :kanji}], QRSegmenter.segment("漢字")
  end

  def test_mixed_string_splits_into_modes
    segments = QRSegmenter.segment("123ABC漢字abc")
    assert_equal [
      {data: "123ABC", mode: :alphanumeric},
      {data: "漢字", mode: :kanji},
      {data: "abc", mode: :byte_8bit}
    ], segments
  end

  def test_long_numeric_run_uses_numeric_mode
    segments = QRSegmenter.segment("1" * 20 + "a")
    assert_equal [
      {data: "1" * 20, mode: :number},
      {data: "a", mode: :byte_8bit}
    ], segments
  end

  def test_halfwidth_katakana_switch_to_shift_jis_eci
    segments = QRSegmenter.segment("ｱ" * 10)
    assert_equal [
      {data: 20, mode: :eci},
      {data: "ｱ" * 10, mode: :byte_8bit}
    ], segments.map { |s| s[:mode] == :byte_8bit ? s.merge(data: s[:data].encode(Encoding::UTF_8)) : s }
  end

  def test_eci_switch_back_to_utf8
    segments = QRSegmenter.segment("ｱ" * 5 + "🎉" * 3)
    assert_equal [:eci, :byte_8bit, :eci, :byte_8bit], segments.map { |s| s[:mode] }
    assert_equal 20, segments[0][:data]
    assert_equal Encoding::Shift_JIS, segments[1][:data].encoding
    assert_equal "ｱ" * 5, segments[1][:data].encode(Encoding::UTF_8)
    assert_equal 26, segments[2][:data]
    assert_equal "🎉" * 3, segments[3][:data]
  end

  def test_dp_bits_match_segment_sizes
    ["123ABC漢字abcｱｲｳ", "TEL:03-1234 漢字テスト🎉", "ｱｲｳｴｵ", "1"].each do |string|
      GROUP_VERSION.each_with_index do |version, group|
        segments = QRSegmenter.segment(string, version_group: group)
        assert_equal QRSegmenter.minimum_bits(string, version_group: group),
          segment_bits(segments, version),
          "DP bit count must equal the produced segment sizes for #{string.inspect} (group #{group})"
      end
    end
  end

  # For every short string over the mode-covering alphabet, the optimizer
  # must find exactly the minimum bit count over all legal segmentations,
  # in every version group (character count field widths differ).
  def test_exhaustive_short_strings_match_brute_force
    GROUP_VERSION.each_with_index do |version, group|
      (1..4).each do |length|
        ALPHABET.repeated_permutation(length) do |chars|
          string = chars.join
          expected = brute_force_minimum_bits(string, version)
          actual = QRSegmenter.minimum_bits(string, version_group: group)
          assert_equal expected, actual,
            "minimum bits mismatch for #{string.inspect} in version group #{group}"

          segments = QRSegmenter.segment(string, version_group: group)
          assert_equal expected, segment_bits(segments, version),
            "produced segments do not achieve the minimum for #{string.inspect} in version group #{group}"
        end
      end
    end
  end

  # 111 kanji at level :m need 12 + 111 * 13 = 1455 bits, one bit below
  # the 1456 bit capacity of version 9-M. One more kanji crosses into the
  # 10-26 version group where the kanji character count field is 10 bits.
  def test_version_9_to_10_boundary
    assert_equal 9, QRCode.new("漢" * 111, mode: :auto, level: :m).version
    assert_equal 10, QRCode.new("漢" * 112, mode: :auto, level: :m).version
  end

  # 841 kanji at level :l need 14 + 841 * 13 = 10947 bits (version 26-L
  # holds 10960). One more kanji needs exactly 10960 bits which does not
  # satisfy the strict capacity check, crossing into the 27-40 group.
  def test_version_26_to_27_boundary
    assert_equal 26, QRCode.new("漢" * 841, mode: :auto, level: :l).version
    assert_equal 27, QRCode.new("漢" * 842, mode: :auto, level: :l).version
  end

  def test_auto_mode_beats_single_byte_mode
    string = "TEL:03-1234-5678 漢字テスト"
    auto = QRCode.new(string, mode: :auto, level: :m)
    plain = QRCode.new(string, level: :m)
    assert auto.version < plain.version
    assert auto.multi_segment?
  end

  def test_auto_mode_with_mixed_japanese_and_numbers
    qr = QRCode.new("注文12345番: 漢字とカタカナ", mode: :auto)
    assert qr.modules.size > 0
    assert qr.multi_segment?
  end

  def test_auto_mode_respects_forced_size
    qr = QRCode.new("漢字abc123", mode: :auto, size: 5)
    assert_equal 5, qr.version
  end

  def test_auto_mode_respects_max_size
    assert_raises(RQRCodeCore::QRCodeRunTimeError) do
      QRCode.new("漢" * 200, mode: :auto, level: :h, max_size: 5)
    end
  end

  def test_auto_mode_with_empty_string
    qr = QRCode.new("", mode: :auto)
    assert_equal 1, qr.version
  end
end
