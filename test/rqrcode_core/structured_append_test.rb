require "test_helper"

# Tests for Structured Append symbol series generation
class StructuredAppendTest < Minitest::Test
  # Independent bit reader used to verify the encoded bit stream
  class BitReader
    def initialize(bytes)
      @bytes = bytes
      @bit = 0
    end

    def read(length)
      value = 0
      length.times do
        value = (value << 1) | ((@bytes[@bit / 8] >> (7 - @bit % 8)) & 1)
        @bit += 1
      end
      value
    end
  end

  def data_codewords(qr)
    blocks = RQRCodeCore::QRRSBlock.get_rs_blocks(qr.version, RQRCodeCore::QRERRORCORRECTLEVEL[qr.error_correction_level])
    assert_equal 1, blocks.size, "test helper expects a single RS block"
    qr.instance_variable_get(:@data_cache).first(blocks.first.data_count)
  end

  def read_header(qr)
    reader = BitReader.new(data_codewords(qr))
    {
      mode: reader.read(4),
      position: reader.read(4),
      total: reader.read(4) + 1,
      parity: reader.read(8),
      reader: reader
    }
  end

  def read_byte_payload(qr)
    header = read_header(qr)
    reader = header[:reader]
    assert_equal 0b0100, reader.read(4), "expected 8bit byte mode indicator"
    length = reader.read(8)
    length.times.map { reader.read(8) }
  end

  def xor_parity(data)
    data.bytes.reduce(0) { |acc, byte| acc ^ byte }
  end

  def test_returns_single_plain_symbol_when_data_fits
    symbols = RQRCodeCore::QRStructuredAppend.encode("HELLO WORLD", level: :h, max_size: 4)

    assert_equal 1, symbols.size
    refute symbols.first.structured_append?
    assert_nil symbols.first.structured_append
    assert_equal RQRCodeCore::QRCode.new("HELLO WORLD", level: :h).version, symbols.first.version
  end

  def test_single_symbol_matches_plain_qrcode_exactly
    symbols = RQRCodeCore::QRStructuredAppend.encode("HELLO WORLD", level: :m, max_size: 3)
    plain = RQRCodeCore::QRCode.new("HELLO WORLD", level: :m)

    assert_equal plain.modules, symbols.first.modules
  end

  def test_splits_into_structured_append_symbols_when_data_exceeds_max_size
    data = "A" * 41
    symbols = RQRCodeCore::QRStructuredAppend.encode(data, level: :h, max_size: 1)

    assert symbols.size > 1, "expected the data to be split"
    assert symbols.all?(&:structured_append?)
    assert symbols.all? { |qr| qr.version <= 1 }
    assert_equal (0...symbols.size).to_a, symbols.map { |qr| qr.structured_append[:position] }
    assert symbols.all? { |qr| qr.structured_append[:total] == symbols.size }
    assert symbols.all? { |qr| qr.structured_append[:parity] == xor_parity(data) }
  end

  def test_header_fields_via_independent_bitstream_reading
    data = "AB" * 20
    symbols = RQRCodeCore::QRStructuredAppend.encode(data, level: :h, max_size: 1)

    symbols.each_with_index do |qr, index|
      header = read_header(qr)
      assert_equal 0b0011, header[:mode], "structured append mode indicator"
      assert_equal index, header[:position]
      assert_equal symbols.size, header[:total]
      assert_equal xor_parity(data), header[:parity]
      assert_equal 0b0010, header[:reader].read(4), "alphanumeric mode indicator follows the header"
    end
  end

  def test_multibyte_characters_are_never_split
    data = "日本語のテキストです" * 3
    symbols = RQRCodeCore::QRStructuredAppend.encode(data, level: :m, max_size: 1)

    assert symbols.size > 1, "expected the data to be split"

    payloads = symbols.map { |qr| read_byte_payload(qr) }
    payloads.each do |payload|
      assert payload.pack("C*").force_encoding(Encoding::UTF_8).valid_encoding?, "chunk boundary splits a multi-byte character"
    end
    assert_equal data.bytes, payloads.flatten, "reassembled payloads must equal the original data"
  end

  def test_capacity_accounts_for_structured_append_header
    # 7 bytes fit a version 1-H symbol without a header (68 of 72 bits) but
    # not once the 20 bit structured append header is included (88 bits)
    plain = RQRCodeCore::QRCode.new("abcdefg", level: :h)
    assert_equal 1, plain.version

    headed = RQRCodeCore::QRCode.new("abcdefg", level: :h, structured_append: {position: 0, total: 2, parity: 0})
    assert_equal 2, headed.version

    error = assert_raises(RQRCodeCore::QRCodeRunTimeError) do
      RQRCodeCore::QRCode.new("abcdefg", level: :h, size: 1, structured_append: {position: 0, total: 2, parity: 0})
    end
    assert_match(/overflow/, error.message)
  end

  def test_raises_when_more_than_16_symbols_are_required
    error = assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRStructuredAppend.encode("x" * 500, level: :h, max_size: 1)
    end
    assert_match(/16/, error.message)
  end

  def test_validates_arguments
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRStructuredAppend.encode(123) }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRStructuredAppend.encode("abc", level: :x) }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRStructuredAppend.encode("abc", max_size: 0) }
    assert_raises(RQRCodeCore::QRCodeArgumentError) { RQRCodeCore::QRStructuredAppend.encode("abc", max_size: 41) }
  end

  def test_validates_structured_append_option
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRCode.new("abc", structured_append: {position: 0, total: 1, parity: 0})
    end
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRCode.new("abc", structured_append: {position: 0, total: 17, parity: 0})
    end
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRCode.new("abc", structured_append: {position: 2, total: 2, parity: 0})
    end
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRCode.new("abc", structured_append: {position: 0, total: 2, parity: 256})
    end
  end

  # Exhaustively checks every contiguous segmentation of a small input and
  # verifies the encoder picks the fewest symbols, then the smallest
  # largest version
  def test_exhaustive_segmentation_matches_optimal_choice
    [
      ["abcdefghijk", :byte_8bit],
      ["AB1CD2EF3GH", :alphanumeric],
      ["12345678901", :number]
    ].each do |data, mode|
      [:l, :h].each do |level|
        symbols = RQRCodeCore::QRStructuredAppend.encode(data, level: level, max_size: 1)
        expected_count, expected_max_version = brute_force_optimum(data, mode, level, 1)

        assert_equal expected_count, symbols.size, "symbol count for #{data.inspect} (#{level})"
        assert_equal expected_max_version, symbols.map(&:version).max, "max version for #{data.inspect} (#{level})"
      end
    end
  end

  private

  def brute_force_optimum(data, mode, level, max_size)
    length = data.length
    (1..16).each do |count|
      best_max = nil
      each_composition(length, count) do |parts|
        offset = 0
        versions = parts.map do |part|
          chunk = data[offset, part]
          offset += part
          chunk_min_version(chunk, mode, level, max_size)
        end
        next if versions.any?(&:nil?)
        best_max = [best_max, versions.max].compact.min
      end
      return [count, best_max] if best_max
    end
    nil
  end

  def each_composition(length, count)
    return enum_for(:each_composition, length, count) unless block_given?
    if count == 1
      yield [length]
      return
    end
    (1..(length - count + 1)).each do |first|
      each_composition(length - first, count - 1) do |rest|
        yield [first, *rest]
      end
    end
  end

  def chunk_min_version(chunk, mode, level, max_size)
    segment = RQRCodeCore::QRSegment.new(data: chunk, mode: mode)
    (1..max_size).find do |version|
      20 + segment.size(version) < RQRCodeCore::QRMAXBITS[level][version - 1]
    end
  end
end
