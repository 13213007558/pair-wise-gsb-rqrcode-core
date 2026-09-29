require "test_helper"

# Tests for Structured Append symbol generation (ISO/IEC 18004)
class StructuredAppendTest < Minitest::Test
  # Independent bit reader used to verify the encoded header fields
  # without relying on the writer implementation.
  class BitReader
    def initialize(buffer)
      @buffer = buffer
      @position = 0
    end

    def read(length)
      value = 0
      length.times do
        value = (value << 1) | (@buffer.get(@position) ? 1 : 0)
        @position += 1
      end
      value
    end
  end

  def bitstream_of(qr)
    buffer = RQRCodeCore::QRBitBuffer.new(qr.version)
    qr.instance_variable_get(:@data_list).write(buffer)
    buffer
  end

  def naive_chunk_version(chunk, level, max_size, header_bits)
    (1..max_size).each do |version|
      size_bits = header_bits + RQRCodeCore::QRSegment.new(data: chunk).size(version)
      return version if size_bits < RQRCodeCore::QRMAXBITS[level][version - 1]
    end
    nil
  end

  # Brute force optimum over every possible partition: fewest symbols
  # first, then smallest largest version.
  def brute_force_optimum(chars, level, max_size)
    plain = naive_chunk_version(chars.join, level, max_size, 0)
    return [1, plain] if plain

    best = nil
    each_partition(chars) do |parts|
      versions = parts.map { |part| naive_chunk_version(part, level, max_size, 20) }
      next if versions.any?(&:nil?)
      cost = [parts.size, versions.max]
      best = cost if best.nil? || (cost <=> best) < 0
    end
    best
  end

  def each_partition(chars, &block)
    return if chars.empty?
    partitions = []
    (0...(1 << (chars.size - 1))).each do |mask|
      parts = []
      current = chars.first.dup
      chars.each_with_index do |char, index|
        next if index.zero?
        if (mask & (1 << (index - 1))) != 0
          parts << current
          current = char.dup
        else
          current << char
        end
      end
      partitions << parts + [current]
    end
    partitions.group_by(&:size).sort.each do |_, grouped|
      grouped.each(&block)
    end
  end

  def test_returns_single_plain_symbol_when_data_fits
    sa = RQRCodeCore::QRStructuredAppend.new("HELLO WORLD", level: :h, max_size: 4)

    assert_equal 1, sa.count
    refute sa.structured_append?
    assert_nil sa.symbols.first.structured_append
    assert_equal ["HELLO WORLD"], sa.chunks

    plain = RQRCodeCore::QRCode.new("HELLO WORLD", level: :h)
    assert_equal plain.modules, sa.symbols.first.modules
  end

  def test_splits_into_multiple_symbols_when_data_exceeds_max_size
    data = "x" * 18
    sa = RQRCodeCore::QRStructuredAppend.new(data, level: :l, max_size: 1)

    assert sa.structured_append?
    assert_equal 2, sa.count
    assert_equal data, sa.chunks.join
    sa.symbols.each do |symbol|
      assert symbol.version <= 1, "Each symbol must fit within max_size"
    end
  end

  def test_symbol_capacity_accounts_for_structured_append_header
    # Version 1-L holds 152 bits. A byte chunk of 15 characters needs
    # 4 + 8 + 120 = 132 bits and fits, but with the 20 bit Structured
    # Append header it needs 152 bits and no longer fits, so chunks must
    # be at most 14 bytes.
    sa = RQRCodeCore::QRStructuredAppend.new("x" * 18, level: :l, max_size: 1)

    assert_equal [14, 4], sa.chunks.map(&:bytesize)

    sa.chunks.each_with_index do |chunk, index|
      version = sa.symbols[index].version
      size_bits = 20 + RQRCodeCore::QRSegment.new(data: chunk).size(version)
      assert size_bits < RQRCodeCore::QRMAXBITS[:l][version - 1],
        "Symbol #{index} must fit including the Structured Append header"
    end
  end

  def test_parity_is_xor_of_all_original_bytes
    data = "PARITY CHECK 123 é"
    sa = RQRCodeCore::QRStructuredAppend.new(data, level: :m, max_size: 1)

    expected = data.bytes.reduce(0) { |acc, byte| acc ^ byte }
    assert_equal expected, sa.parity
    sa.symbols.each do |symbol|
      assert_equal expected, symbol.structured_append[:parity]
    end
  end

  def test_header_fields_readable_from_encoded_bitstream
    data = "BITSTREAM VERIFICATION 0123456789"
    sa = RQRCodeCore::QRStructuredAppend.new(data, level: :h, max_size: 2)

    assert sa.structured_append?
    sa.symbols.each_with_index do |symbol, index|
      reader = BitReader.new(bitstream_of(symbol))

      assert_equal 0b0011, reader.read(4), "Symbol #{index} must start with the Structured Append mode indicator"
      assert_equal index, reader.read(4), "Symbol #{index} must carry its own position"
      assert_equal sa.count - 1, reader.read(4), "Symbol #{index} must carry the total symbol count minus one"
      assert_equal sa.parity, reader.read(8), "Symbol #{index} must carry the shared parity"
    end
  end

  def test_payload_matches_independent_encoding_of_chunk
    data = "PAYLOAD 1234567890 éé"
    sa = RQRCodeCore::QRStructuredAppend.new(data, level: :q, max_size: 2)

    sa.symbols.each_with_index do |symbol, index|
      buffer = bitstream_of(symbol)
      expected = RQRCodeCore::QRBitBuffer.new(symbol.version)
      RQRCodeCore::QRSegment.new(data: sa.chunks[index]).writer.write(expected)

      assert_equal expected.get_length_in_bits, buffer.get_length_in_bits - 20
      expected.get_length_in_bits.times do |bit|
        assert_equal expected.get(bit), buffer.get(20 + bit),
          "Payload bit #{bit} of symbol #{index} must match an independent encoding of its chunk"
      end
    end
  end

  def test_multibyte_characters_are_never_split
    data = "你好世界，这是一个多字节字符的测试"
    sa = RQRCodeCore::QRStructuredAppend.new(data, level: :h, max_size: 2)

    assert sa.structured_append?
    assert_equal data, sa.chunks.join
    sa.chunks.each do |chunk|
      assert chunk.valid_encoding?, "Chunk #{chunk.inspect} must not split a multi-byte character"
    end
  end

  def test_selection_prefers_fewest_symbols_then_smallest_largest_version
    # 100 bytes at level :l do not fit in one version 4 symbol (75 bytes with
    # header). Two symbols suffice, and the largest version is minimized:
    # version 3 holds 50 bytes per symbol, so 50 + 50 at version 3 is chosen
    # over 75 + 25 at version 4.
    sa = RQRCodeCore::QRStructuredAppend.new("x" * 100, level: :l, max_size: 4)

    assert_equal 2, sa.count
    assert_equal [50, 50], sa.chunks.map(&:bytesize)
    assert_equal [3, 3], sa.symbols.map(&:version)
  end

  def test_fewest_symbols_wins_over_smaller_versions
    # 130 bytes at level :l: 2 symbols require version 4 (75 + 55) while
    # 3 symbols would fit in version 3 (50 each). Fewest symbols wins.
    sa = RQRCodeCore::QRStructuredAppend.new("x" * 130, level: :l, max_size: 4)

    assert_equal 2, sa.count
    assert_equal [75, 55], sa.chunks.map(&:bytesize)
    assert_equal [4, 4], sa.symbols.map(&:version)
  end

  def test_stable_fill_from_start_tie_break
    # Two symbols are needed; the first must be filled as much as possible
    # instead of balancing the chunks.
    sa = RQRCodeCore::QRStructuredAppend.new("x" * 18, level: :l, max_size: 1)
    assert_equal ["x" * 14, "x" * 4], sa.chunks

    again = RQRCodeCore::QRStructuredAppend.new("x" * 18, level: :l, max_size: 1)
    assert_equal sa.chunks, again.chunks
    assert_equal sa.symbols.map(&:modules), again.symbols.map(&:modules)
  end

  def test_exhaustive_small_inputs_match_brute_force_optimum
    alphabet = ["1", "A", "é"]
    level = :h
    max_size = 1

    (1..5).each do |length|
      alphabet.repeated_permutation(length) do |chars|
        data = chars.join
        sa = RQRCodeCore::QRStructuredAppend.new(data, level: level, max_size: max_size)
        optimum = brute_force_optimum(chars, level, max_size)

        assert_equal optimum[0], sa.count,
          "Symbol count for #{data.inspect} must be optimal"
        assert_equal optimum[1], sa.symbols.map(&:version).max,
          "Largest version for #{data.inspect} must be minimal for #{optimum[0]} symbols"
        assert_equal data, sa.chunks.join
      end
    end
  end

  def test_allows_up_to_sixteen_symbols
    # Version 1-H fits 4 bytes per symbol once the header is accounted for.
    sa = RQRCodeCore::QRStructuredAppend.new("x" * 64, level: :h, max_size: 1)

    assert_equal 16, sa.count
    sa.symbols.each_with_index do |symbol, index|
      assert_equal index, symbol.structured_append[:position]
      assert_equal 16, symbol.structured_append[:total]
    end
  end

  def test_raises_when_more_than_sixteen_symbols_are_needed
    error = assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRStructuredAppend.new("x" * 65, level: :h, max_size: 1)
    end
    assert_match(/16 symbols/, error.message)
  end

  def test_validates_arguments
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRStructuredAppend.new(nil, level: :h, max_size: 1)
    end
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRStructuredAppend.new("data", level: :z, max_size: 1)
    end
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRStructuredAppend.new("data", level: :h, max_size: 0)
    end
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRStructuredAppend.new("data", level: :h, max_size: 41)
    end
  end

  def test_qrcode_structured_append_option_counts_header_towards_capacity
    plain = RQRCodeCore::QRCode.new("x" * 15, level: :l)
    assert_equal 1, plain.version

    appended = RQRCodeCore::QRCode.new("x" * 15, level: :l,
      structured_append: {position: 0, total: 2, parity: 0x78})
    assert_equal 2, appended.version
    assert_equal({position: 0, total: 2, parity: 0x78}, appended.structured_append)
  end

  def test_qrcode_structured_append_option_requires_all_keys
    assert_raises(RQRCodeCore::QRCodeArgumentError) do
      RQRCodeCore::QRCode.new("data", structured_append: {position: 0})
    end
  end
end
