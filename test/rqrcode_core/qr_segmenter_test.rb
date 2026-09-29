# frozen_string_literal: true

require "test_helper"

class RQRCodeCore::QRSegmenterTest < Minitest::Test
  # One representative of every character class the segmenter understands:
  # numeric-only, alphanumeric-only, byte-only (ISO-8859-1), kanji,
  # Latin-1 byte and Shift_JIS-only (half-width kana)
  ALPHABET = ["1", "A", "a", "日", "é", "ｱ"].freeze

  ECI_UTF8 = 26
  ECI_SHIFT_JIS = 20

  # Byte encodings a byte segment may use, keyed by the ECI assignment
  # number that has to be in effect (nil = default interpretation)
  BYTE_ENCODINGS = {
    nil => Encoding::ISO_8859_1,
    ECI_UTF8 => Encoding::UTF_8,
    ECI_SHIFT_JIS => Encoding::SHIFT_JIS
  }.freeze

  VERSION_GROUPS = [(1..9), (10..26), (27..40)].freeze

  # Exhaustively enumerates every legal segmentation of +chars+ (every split
  # point, every legal mode per segment, every legal byte encoding and ECI
  # switch) and returns the minimum possible number of bits.
  def brute_force_min_bits(chars, version)
    header = {
      number: 4 + RQRCodeCore::QRUtil.get_length_in_bits(RQRCodeCore::QRMODE[:mode_number], version),
      alphanumeric: 4 + RQRCodeCore::QRUtil.get_length_in_bits(RQRCodeCore::QRMODE[:mode_alpha_numk], version),
      kanji: 4 + RQRCodeCore::QRUtil.get_length_in_bits(RQRCodeCore::QRMODE[:mode_kanji], version),
      byte: 4 + RQRCodeCore::QRUtil.get_length_in_bits(RQRCodeCore::QRMODE[:mode_8bit_byte], version)
    }
    enumerate(chars, 0, nil, header, {})
  end

  def enumerate(chars, i, eci, header, memo)
    return 0 if i == chars.length

    key = [i, eci]
    return memo[key] if memo.key?(key)

    best = Float::INFINITY
    length = chars.length

    if numeric_char?(chars[i])
      j = i
      while j < length && numeric_char?(chars[j])
        j += 1
        run = j - i
        cost = header[:number] + (run / 3) * 10 + [0, 4, 7][run % 3] + enumerate(chars, j, eci, header, memo)
        best = cost if cost < best
      end
    end

    if RQRCodeCore::ALPHANUMERIC.include?(chars[i])
      j = i
      while j < length && RQRCodeCore::ALPHANUMERIC.include?(chars[j])
        j += 1
        run = j - i
        cost = header[:alphanumeric] + (run / 2) * 11 + (run % 2) * 6 + enumerate(chars, j, eci, header, memo)
        best = cost if cost < best
      end
    end

    if RQRCodeCore::QRKanji.kanji_char?(chars[i])
      j = i
      while j < length && RQRCodeCore::QRKanji.kanji_char?(chars[j])
        j += 1
        cost = header[:kanji] + 13 * (j - i) + enumerate(chars, j, eci, header, memo)
        best = cost if cost < best
      end
    end

    BYTE_ENCODINGS.each do |assignment, encoding|
      next if assignment.nil? && !eci.nil? # an emitted ECI header cannot be revoked

      switch_cost = (assignment == eci) ? 0 : 4 + 8 # mode indicator + designator
      bytes = 0
      j = i
      while j < length && (size = byte_size(chars[j], encoding))
        bytes += size
        j += 1
        cost = header[:byte] + switch_cost + 8 * bytes + enumerate(chars, j, assignment, header, memo)
        best = cost if cost < best
      end
    end

    memo[key] = best
  end

  def numeric_char?(char)
    RQRCodeCore::NUMERIC.include?(char)
  end

  def byte_size(char, encoding)
    char.encode(encoding).bytesize
  rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
    nil
  end

  def each_short_string(&block)
    (1..3).each do |length|
      ALPHABET.repeated_permutation(length).each { |chars| block.call(chars.join) }
    end
  end

  def expected_version(string, level)
    (1..40).each do |version|
      group = VERSION_GROUPS.find { |g| g.cover?(version) }
      bits = brute_force_min_bits(string.chars, group.first)
      return version if bits < RQRCodeCore::QRMAXBITS[level][version - 1]
    end
    nil
  end

  def test_exhaustive_short_strings_achieve_minimum_bits_in_every_version_group
    each_short_string do |string|
      segmenter = RQRCodeCore::QRSegmenter.new(string, :h)

      VERSION_GROUPS.each do |group|
        expected = brute_force_min_bits(string.chars, group.first)
        bits, = segmenter.send(:optimize_for_group, group)

        assert_equal expected, bits, "Expected #{string.inspect} to take #{expected} bits in versions #{group}"
      end
    end
  end

  def test_exhaustive_short_strings_choose_minimum_version
    each_short_string do |string|
      %i[l m q h].each do |level|
        qr = RQRCodeCore::QRCode.new(string, mode: :auto, level: level)

        assert_equal expected_version(string, level), qr.version,
          "Expected #{string.inspect} (level #{level}) to use version #{expected_version(string, level)}"
      end
    end
  end

  def test_random_longer_strings_match_brute_force
    rng = Random.new(20260929)

    200.times do
      string = Array.new(rng.rand(4..12)) { ALPHABET[rng.rand(ALPHABET.size)] }.join
      segmenter = RQRCodeCore::QRSegmenter.new(string, :h)

      VERSION_GROUPS.each do |group|
        expected = brute_force_min_bits(string.chars, group.first)
        bits, = segmenter.send(:optimize_for_group, group)

        assert_equal expected, bits, "Expected #{string.inspect} to take #{expected} bits in versions #{group}"
      end
    end
  end

  def test_segments_encode_the_original_string
    each_short_string do |string|
      qr = RQRCodeCore::QRCode.new(string, mode: :auto, level: :h)

      refute_nil qr.modules
    end
  end

  def test_pure_numeric_uses_single_number_segment
    assert_equal [{data: "0123456789", mode: :number}], RQRCodeCore::QRSegmenter.segment("0123456789")
  end

  def test_pure_alphanumeric_uses_single_segment
    assert_equal [{data: "ABC 123", mode: :alphanumeric}], RQRCodeCore::QRSegmenter.segment("ABC 123")
  end

  def test_pure_kanji_uses_single_kanji_segment
    assert_equal [{data: "日本語", mode: :kanji}], RQRCodeCore::QRSegmenter.segment("日本語")
  end

  def test_ascii_byte_data_needs_no_eci_header
    segments = RQRCodeCore::QRSegmenter.segment("hello world")

    assert_equal [{data: "hello world", mode: :byte_8bit}], segments
  end

  def test_latin1_data_uses_default_interpretation_without_eci
    segments = RQRCodeCore::QRSegmenter.segment("café")

    assert_equal [{data: "café".encode(Encoding::ISO_8859_1), mode: :byte_8bit}], segments
    assert_equal 1, segments.first[:data].bytesize - "caf".bytesize
  end

  def test_mixed_content_is_split_into_optimal_segments
    segments = RQRCodeCore::QRSegmenter.segment("Hello 世界123")

    assert_equal [
      {data: "Hello ", mode: :byte_8bit},
      {data: "世界", mode: :kanji},
      {data: "123", mode: :number}
    ], segments
  end

  def test_non_kanji_cjk_uses_utf8_byte_segment_with_eci
    # 你 has no Shift_JIS mapping and must not end up in a kanji segment
    segments = RQRCodeCore::QRSegmenter.segment("你好世界")

    assert_equal [
      {data: 26, mode: :eci},
      {data: "你", mode: :byte_8bit},
      {data: "好世界", mode: :kanji}
    ], segments
    assert_equal "你".encode(Encoding::UTF_8).bytes, segments[1][:data].bytes
  end

  def test_half_width_kana_uses_shift_jis_byte_segment_with_eci
    segments = RQRCodeCore::QRSegmenter.segment("ｱｲｳ")

    assert_equal [
      {data: 20, mode: :eci},
      {data: "ｱｲｳ".encode(Encoding::SHIFT_JIS), mode: :byte_8bit}
    ], segments
    assert_equal [0xB1, 0xB2, 0xB3], segments[1][:data].bytes
  end

  def test_eci_switching_cost_prefers_single_utf8_segment
    # Splitting into Shift_JIS + Latin-1 runs would need two ECI switches;
    # one UTF-8 segment with a single ECI header is cheaper
    segments = RQRCodeCore::QRSegmenter.segment("ｱéｱ")

    assert_equal [
      {data: 26, mode: :eci},
      {data: "ｱéｱ".encode(Encoding::UTF_8), mode: :byte_8bit}
    ], segments
  end

  def test_empty_string
    assert_equal [], RQRCodeCore::QRSegmenter.segment("")
    assert_equal 1, RQRCodeCore::QRCode.new("", mode: :auto).version
  end

  def test_auto_mode_beats_single_byte_mode_for_mixed_content
    data = "注文1234: 東京タワーまでABC"

    auto = RQRCodeCore::QRCode.new(data, mode: :auto, level: :h)
    byte = RQRCodeCore::QRCode.new(data, level: :h)

    assert auto.version < byte.version
  end

  def test_auto_mode_respects_forced_size
    qr = RQRCodeCore::QRCode.new("日本語123", mode: :auto, size: 5)

    assert_equal 5, qr.version
  end

  def test_auto_mode_raises_when_data_exceeds_max_size
    assert_raises(RQRCodeCore::QRCodeRunTimeError) do
      RQRCodeCore::QRCode.new("あ" * 100, mode: :auto, level: :h, max_size: 2)
    end
  end

  # Version boundary examples: byte segment crossing the 8 -> 16 bit
  # character count indicator boundary between versions 9 and 10
  def test_byte_data_just_below_version_10_boundary
    # 4 + 8 + 8 * 230 = 1852 bits fits version 9-L (1856 bits)
    assert_equal 9, RQRCodeCore::QRCode.new("a" * 230, mode: :auto, level: :l).version
  end

  def test_byte_data_just_above_version_10_boundary
    # 4 + 8 + 8 * 231 = 1860 bits needs version 10-L (2192 bits, 16 bit count)
    assert_equal 10, RQRCodeCore::QRCode.new("a" * 231, mode: :auto, level: :l).version
  end

  # Kanji segment crossing the 8 -> 10 bit count indicator boundary
  def test_kanji_data_just_below_version_10_boundary
    # 4 + 8 + 13 * 141 = 1845 bits fits version 9-L
    assert_equal 9, RQRCodeCore::QRCode.new("あ" * 141, mode: :auto, level: :l).version
  end

  def test_kanji_data_just_above_version_10_boundary
    # 4 + 8 + 13 * 142 = 1858 bits needs version 10-L (10 bit count)
    assert_equal 10, RQRCodeCore::QRCode.new("あ" * 142, mode: :auto, level: :l).version
  end

  # Kanji segment crossing the 10 -> 12 bit count indicator boundary
  def test_kanji_data_just_below_version_27_boundary
    # 4 + 10 + 13 * 841 = 10947 bits fits version 26-L (10960 bits)
    assert_equal 26, RQRCodeCore::QRCode.new("あ" * 841, mode: :auto, level: :l).version
  end

  def test_kanji_data_just_above_version_27_boundary
    # 4 + 10 + 13 * 842 = 10960 bits needs version 27-L (12 bit count)
    assert_equal 27, RQRCodeCore::QRCode.new("あ" * 842, mode: :auto, level: :l).version
  end
end
