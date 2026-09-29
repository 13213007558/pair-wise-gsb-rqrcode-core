# frozen_string_literal: true

require "test_helper"

class RQRCodeCore::QRKanjiTest < Minitest::Test
  def test_valid_data_accepts_shift_jis_double_byte_characters
    assert RQRCodeCore::QRKanji.valid_data?("日本語")
    assert RQRCodeCore::QRKanji.valid_data?("あいうえお")
    assert RQRCodeCore::QRKanji.valid_data?("アイウエオ")
    assert RQRCodeCore::QRKanji.valid_data?("茗荷")
    assert RQRCodeCore::QRKanji.valid_data?("、。")
  end

  def test_valid_data_rejects_non_kanji_characters
    refute RQRCodeCore::QRKanji.valid_data?("ABC")
    refute RQRCodeCore::QRKanji.valid_data?("abc")
    refute RQRCodeCore::QRKanji.valid_data?("123")
    refute RQRCodeCore::QRKanji.valid_data?("ｱｲｳ") # half-width kana are single byte in Shift_JIS
    refute RQRCodeCore::QRKanji.valid_data?("日本語abc")
  end

  def test_valid_data_rejects_characters_not_in_shift_jis
    refute RQRCodeCore::QRKanji.valid_data?("你") # U+4F60 has no Shift_JIS mapping
    refute RQRCodeCore::QRKanji.valid_data?("😀")
    refute RQRCodeCore::QRKanji.valid_data?("日本你")
  end

  def test_kanji_code_matches_specification_examples
    # Worked example from the QR specification: 茗荷 -> 0x1AAA 0x0697
    assert_equal 0x1AAA, RQRCodeCore::QRKanji.kanji_code("茗")
    assert_equal 0x697, RQRCodeCore::QRKanji.kanji_code("荷")
    # あ is Shift_JIS 0x82A0 -> (0x82A0 - 0x8140) = 0x0160 -> 0x01 * 0xC0 + 0x60
    assert_equal 0x120, RQRCodeCore::QRKanji.kanji_code("あ")
  end

  def test_write_produces_specification_bit_stream
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QRKanji.new("茗荷").write(buffer)

    expected = "1000" + "00000010" + format("%013b", 0x1AAA) + format("%013b", 0x697)
    actual = (0...buffer.get_length_in_bits).map { |i| buffer.get(i) ? "1" : "0" }.join

    assert_equal expected, actual
  end

  def test_write_uses_version_dependent_count_indicator
    buffer = RQRCodeCore::QRBitBuffer.new(10)
    RQRCodeCore::QRKanji.new("日本").write(buffer)

    # 4 (mode) + 10 (count for versions 10-26) + 2 * 13
    assert_equal 4 + 10 + 26, buffer.get_length_in_bits
  end

  def test_raises_for_non_kanji_data
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRKanji.new("abc") }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRKanji.new("你") }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRKanji.new("日本a") }
  end

  def test_segment_size_includes_kanji_count_indicator
    segment = RQRCodeCore::QRSegment.new(data: "日本語", mode: :kanji)

    assert_equal 4 + 8 + 3 * 13, segment.size(1)
    assert_equal 4 + 10 + 3 * 13, segment.size(10)
    assert_equal 4 + 12 + 3 * 13, segment.size(27)
  end

  def test_qrcode_with_kanji_mode
    qr = RQRCodeCore::QRCode.new("日本語のテスト", mode: :kanji)

    assert_equal :mode_kanji, qr.mode
    refute_nil qr.modules
  end

  def test_qrcode_with_kanji_mode_rejects_non_shift_jis_data
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRCode.new("你好", mode: :kanji)
    end
  end

  def test_kanji_mode_is_more_compact_than_byte_mode
    data = "日本語のテストです" * 3

    kanji = RQRCodeCore::QRCode.new(data, mode: :kanji, level: :h)
    byte = RQRCodeCore::QRCode.new(data, mode: :byte_8bit, level: :h)

    assert kanji.version < byte.version
  end

  def test_kanji_segment_in_manual_multi_segment_payload
    qr = RQRCodeCore::QRCode.new([
      {data: "TICKET ", mode: :alphanumeric},
      {data: "123", mode: :number},
      {data: "東京", mode: :kanji}
    ])

    assert qr.multi_segment?
    refute_nil qr.modules
  end
end
