# frozen_string_literal: true

require "test_helper"

class RQRCodeCore::QRECITest < Minitest::Test
  def test_designator_bits
    assert_equal 8, RQRCodeCore::QRECI.designator_bits(0)
    assert_equal 8, RQRCodeCore::QRECI.designator_bits(127)
    assert_equal 16, RQRCodeCore::QRECI.designator_bits(128)
    assert_equal 16, RQRCodeCore::QRECI.designator_bits(16_383)
    assert_equal 24, RQRCodeCore::QRECI.designator_bits(16_384)
    assert_equal 24, RQRCodeCore::QRECI.designator_bits(999_999)
  end

  def test_write_single_byte_designator
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QRECI.new(26).write(buffer)

    expected = "0111" + format("%08b", 26)
    actual = (0...buffer.get_length_in_bits).map { |i| buffer.get(i) ? "1" : "0" }.join

    assert_equal expected, actual
  end

  def test_write_two_byte_designator
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QRECI.new(130).write(buffer)

    expected = "0111" + "10" + format("%014b", 130)
    actual = (0...buffer.get_length_in_bits).map { |i| buffer.get(i) ? "1" : "0" }.join

    assert_equal expected, actual
  end

  def test_write_three_byte_designator
    buffer = RQRCodeCore::QRBitBuffer.new(1)
    RQRCodeCore::QRECI.new(17_000).write(buffer)

    expected = "0111" + "110" + format("%021b", 17_000)
    actual = (0...buffer.get_length_in_bits).map { |i| buffer.get(i) ? "1" : "0" }.join

    assert_equal expected, actual
  end

  def test_rejects_out_of_range_assignment_numbers
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRECI.new(-1) }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRECI.new(1_000_000) }
  end

  def test_segment_size_has_no_character_count_indicator
    segment = RQRCodeCore::QRSegment.new(data: 26, mode: :eci)

    assert_equal 4 + 8, segment.size(1)
    assert_equal 4 + 8, segment.size(10)
    assert_equal 4 + 8, segment.size(27)
    assert_equal 4 + 16, RQRCodeCore::QRSegment.new(data: 130, mode: :eci).size(1)
  end

  def test_eci_segment_in_manual_multi_segment_payload
    qr = RQRCodeCore::QRCode.new([
      {data: 26, mode: :eci},
      {data: "hello", mode: :byte_8bit}
    ])

    assert qr.multi_segment?
    assert_equal 1, qr.version
  end

  def test_eci_header_counts_towards_version_capacity
    data = "a" * 17

    without_eci = RQRCodeCore::QRCode.new([{data: data, mode: :byte_8bit}], level: :h)
    with_eci = RQRCodeCore::QRCode.new([{data: 26, mode: :eci}, {data: data, mode: :byte_8bit}], level: :h)

    # 17 bytes = 4 + 8 + 136 = 148 bits fits version 1-H (72)? no: 148 > 72,
    # version 2-H holds 128, version 3-H holds 208
    assert_equal 3, without_eci.version
    assert_equal 3, with_eci.version

    big = "a" * 24
    # 4 + 8 + 192 = 204 bits fits version 3-H (208); adding 12 bits of ECI does not
    assert_equal 3, RQRCodeCore::QRCode.new([{data: big, mode: :byte_8bit}], level: :h).version
    assert_equal 4, RQRCodeCore::QRCode.new([{data: 26, mode: :eci}, {data: big, mode: :byte_8bit}], level: :h).version
  end
end
