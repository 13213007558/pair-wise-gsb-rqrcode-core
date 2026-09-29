# frozen_string_literal: true

require "test_helper"

class RQRCodeCore::QRKanjiTest < Minitest::Test
  def buffer_bits(buffer)
    (0...buffer.get_length_in_bits).map { |i| buffer.get(i) ? "1" : "0" }.join
  end

  def test_valid_data_for_jis_double_byte_characters
    assert RQRCodeCore::QRKanji.valid_data?("漢字")
    assert RQRCodeCore::QRKanji.valid_data?("点茗")
    assert RQRCodeCore::QRKanji.valid_data?("世界")
  end

  def test_invalid_data_for_non_kanji_characters
    refute RQRCodeCore::QRKanji.valid_data?("abc")
    refute RQRCodeCore::QRKanji.valid_data?("漢A字")
    # halfwidth katakana are single-byte in Shift_JIS
    refute RQRCodeCore::QRKanji.valid_data?("ｱｲｳ")
    # simplified Chinese character not in JIS X 0208
    refute RQRCodeCore::QRKanji.valid_data?("汉语")
    refute RQRCodeCore::QRKanji.valid_data?("🎉")
  end

  # Values from the worked example in ISO/IEC 18004: 点 (Shift_JIS 0x935F)
  # and 茗 (Shift_JIS 0xE4AA) encode to 3487 and 6826.
  def test_kanji_code_matches_spec_example
    assert_equal 0x935F, "点".encode(Encoding::Shift_JIS).unpack1("S>")
    assert_equal 0xE4AA, "茗".encode(Encoding::Shift_JIS).unpack1("S>")
    assert_equal 3487, RQRCodeCore::QRKanji.kanji_code("点")
    assert_equal 6826, RQRCodeCore::QRKanji.kanji_code("茗")
  end

  def test_kanji_code_returns_nil_for_unencodable_characters
    assert_nil RQRCodeCore::QRKanji.kanji_code("a")
    assert_nil RQRCodeCore::QRKanji.kanji_code("ｱ")
    assert_nil RQRCodeCore::QRKanji.kanji_code("汉")
  end

  def test_write_produces_spec_bit_stream
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QRKanji.new("点茗").write(buffer)

    expected = "1000" +           # kanji mode indicator
      "00000010" +                # character count (2) in 8 bits for version 1-9
      "0110110011111" +           # 点 => 3487
      "1101010101010"             # 茗 => 6826
    assert_equal expected, buffer_bits(buffer)
  end

  def test_character_count_field_widens_with_version_group
    assert_equal 8, RQRCodeCore::QRUtil.get_length_in_bits(RQRCodeCore::QRMODE[:mode_kanji], 1)
    assert_equal 10, RQRCodeCore::QRUtil.get_length_in_bits(RQRCodeCore::QRMODE[:mode_kanji], 10)
    assert_equal 12, RQRCodeCore::QRUtil.get_length_in_bits(RQRCodeCore::QRMODE[:mode_kanji], 27)
  end

  def test_segment_size_counts_characters_not_bytes
    segment = RQRCodeCore::QRSegment.new(data: "漢字", mode: :kanji)
    assert_equal 4 + 8 + 2 * 13, segment.size(1)
    assert_equal 4 + 10 + 2 * 13, segment.size(10)
    assert_equal 4 + 12 + 2 * 13, segment.size(27)
  end

  def test_qrcode_with_kanji_mode
    qr = RQRCodeCore::QRCode.new("漢字", mode: :kanji)
    assert_equal 1, qr.version
    assert_equal :mode_kanji, qr.mode
  end

  def test_qrcode_with_manual_kanji_segment
    segments = [
      {data: "123", mode: :number},
      {data: "漢字", mode: :kanji},
      {data: "abc", mode: :byte_8bit}
    ]
    qr = RQRCodeCore::QRCode.new(segments)
    assert qr.multi_segment?
    assert qr.modules.size > 0
  end

  def test_raises_for_invalid_kanji_data
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRCode.new("not kanji", mode: :kanji)
    end
  end
end
