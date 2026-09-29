# frozen_string_literal: true

require "test_helper"

class RQRCodeCore::QREciTest < Minitest::Test
  def buffer_bits(buffer)
    (0...buffer.get_length_in_bits).map { |i| buffer.get(i) ? "1" : "0" }.join
  end

  def test_one_byte_designator
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QREci.new(26).write(buffer)

    assert_equal "0111" + "00011010", buffer_bits(buffer)
  end

  def test_two_byte_designator
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QREci.new(130).write(buffer)

    assert_equal "0111" + "10" + "00000010000010".rjust(14, "0"), buffer_bits(buffer)
    assert_equal 4 + 16, buffer.get_length_in_bits
  end

  def test_three_byte_designator
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QREci.new(70_000).write(buffer)

    expected = "0111" + "110" + format("%021b", 70_000)
    assert_equal expected, buffer_bits(buffer)
    assert_equal 4 + 24, buffer.get_length_in_bits
  end

  def test_designator_bits
    assert_equal 8, RQRCodeCore::QREci.designator_bits(0)
    assert_equal 8, RQRCodeCore::QREci.designator_bits(127)
    assert_equal 16, RQRCodeCore::QREci.designator_bits(128)
    assert_equal 16, RQRCodeCore::QREci.designator_bits(16_383)
    assert_equal 24, RQRCodeCore::QREci.designator_bits(16_384)
    assert_equal 24, RQRCodeCore::QREci.designator_bits(999_999)
  end

  def test_named_assignments
    assert_equal 26, RQRCodeCore::QREci.new(:utf8).assignment_number
    assert_equal 20, RQRCodeCore::QREci.new(:shift_jis).assignment_number
    assert_equal 3, RQRCodeCore::QREci.new(:iso8859_1).assignment_number
  end

  def test_invalid_assignment_raises
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QREci.new(-1) }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QREci.new(1_000_000) }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QREci.new(:nope) }
  end

  def test_segment_size_is_mode_indicator_plus_designator
    segment = RQRCodeCore::QRSegment.new(data: 26, mode: :eci)
    assert_equal 4 + 8, segment.size(1)
    assert_equal 4 + 8, segment.size(40)

    big = RQRCodeCore::QRSegment.new(data: 200, mode: :eci)
    assert_equal 4 + 16, big.size(1)
  end

  def test_qrcode_with_manual_eci_segment
    segments = [
      {data: 26, mode: :eci},
      {data: "日本語", mode: :byte_8bit}
    ]
    qr = RQRCodeCore::QRCode.new(segments)
    assert qr.multi_segment?
    assert qr.modules.size > 0
  end
end
