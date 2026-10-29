package msgpack_tests

import msgpack ".."
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_write_nil_and_bools :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	e: msgpack.Encoder
	testing.expect_value(t, msgpack.encoder_init(&e, 0, alloc), nil)
	defer msgpack.encoder_destroy(&e)
	testing.expect_value(t, msgpack.write_nil(&e), nil)
	testing.expect_value(t, msgpack.write_bool(&e, false), nil)
	testing.expect_value(t, msgpack.write_bool(&e, true), nil)
	expect_bytes(t, msgpack.encoder_bytes(&e), {0xc0, 0xc2, 0xc3})
}

@(test)
test_write_uint_picks_smallest_format :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Case :: struct {
		value: u64,
		want:  []byte,
	}
	cases := []Case {
		{0, {0x00}},
		{127, {0x7f}},
		{128, {0xcc, 0x80}},
		{255, {0xcc, 0xff}},
		{256, {0xcd, 0x01, 0x00}},
		{65535, {0xcd, 0xff, 0xff}},
		{65536, {0xce, 0x00, 0x01, 0x00, 0x00}},
		{0xffff_ffff, {0xce, 0xff, 0xff, 0xff, 0xff}},
		{0x1_0000_0000, {0xcf, 0, 0, 0, 1, 0, 0, 0, 0}},
		{max(u64), {0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}},
	}
	e: msgpack.Encoder
	msgpack.encoder_init(&e, 16, alloc)
	defer msgpack.encoder_destroy(&e)
	for c in cases {
		msgpack.encoder_reset(&e)
		testing.expect_value(t, msgpack.write_uint(&e, c.value), nil)
		expect_bytes(t, msgpack.encoder_bytes(&e), c.want)
	}
}

@(test)
test_write_int_picks_smallest_format :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Case :: struct {
		value: i64,
		want:  []byte,
	}
	cases := []Case {
		{5, {0x05}},
		{-1, {0xff}},
		{-32, {0xe0}},
		{-33, {0xd0, 0xdf}},
		{-128, {0xd0, 0x80}},
		{-129, {0xd1, 0xff, 0x7f}},
		{-32768, {0xd1, 0x80, 0x00}},
		{-32769, {0xd2, 0xff, 0xff, 0x7f, 0xff}},
		{i64(min(i32)), {0xd2, 0x80, 0x00, 0x00, 0x00}},
		{i64(min(i32)) - 1, {0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff}},
		{min(i64), {0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0}},
		{300, {0xcd, 0x01, 0x2c}},
	}
	e: msgpack.Encoder
	msgpack.encoder_init(&e, 16, alloc)
	defer msgpack.encoder_destroy(&e)
	for c in cases {
		msgpack.encoder_reset(&e)
		testing.expect_value(t, msgpack.write_int(&e, c.value), nil)
		expect_bytes(t, msgpack.encoder_bytes(&e), c.want)
	}
}

@(test)
test_write_floats :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, alloc)
	defer msgpack.encoder_destroy(&e)
	msgpack.write_f32(&e, 1.5)
	expect_bytes(t, msgpack.encoder_bytes(&e), {0xca, 0x3f, 0xc0, 0x00, 0x00})
	msgpack.encoder_reset(&e)
	msgpack.write_f64(&e, 1.5)
	expect_bytes(t, msgpack.encoder_bytes(&e), {0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0})
}

@(test)
test_write_str_length_boundaries :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, alloc)
	defer msgpack.encoder_destroy(&e)

	Case :: struct {
		n:      int,
		header: []byte,
	}
	cases := []Case {
		{0, {0xa0}},
		{31, {0xbf}},
		{32, {0xd9, 32}},
		{255, {0xd9, 0xff}},
		{256, {0xda, 0x01, 0x00}},
		{65536, {0xdb, 0x00, 0x01, 0x00, 0x00}},
	}
	for c in cases {
		s := strings.repeat("x", c.n, alloc)
		defer delete(s, alloc)
		msgpack.encoder_reset(&e)
		testing.expect_value(t, msgpack.write_str(&e, s), nil)
		out := msgpack.encoder_bytes(&e)
		testing.expect_value(t, len(out), len(c.header) + c.n)
		expect_bytes(t, out[:len(c.header)], c.header)
	}
}

@(test)
test_write_bin_length_boundaries :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, alloc)
	defer msgpack.encoder_destroy(&e)

	Case :: struct {
		n:      int,
		header: []byte,
	}
	cases := []Case{{0, {0xc4, 0}}, {255, {0xc4, 0xff}}, {256, {0xc5, 0x01, 0x00}}, {70000, {0xc6, 0x00, 0x01, 0x11, 0x70}}}
	for c in cases {
		b := make([]byte, c.n, alloc)
		defer delete(b, alloc)
		msgpack.encoder_reset(&e)
		testing.expect_value(t, msgpack.write_bin(&e, b), nil)
		out := msgpack.encoder_bytes(&e)
		testing.expect_value(t, len(out), len(c.header) + c.n)
		expect_bytes(t, out[:len(c.header)], c.header)
	}
}

@(test)
test_write_container_headers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, alloc)
	defer msgpack.encoder_destroy(&e)
	msgpack.write_array_header(&e, 0)
	msgpack.write_array_header(&e, 15)
	msgpack.write_array_header(&e, 16)
	msgpack.write_array_header(&e, 70000)
	msgpack.write_map_header(&e, 1)
	msgpack.write_map_header(&e, 16)
	msgpack.write_map_header(&e, 70000)
	expect_bytes(t, msgpack.encoder_bytes(&e), {
		0x90,
		0x9f,
		0xdc, 0x00, 0x10,
		0xdd, 0x00, 0x01, 0x11, 0x70,
		0x81,
		0xde, 0x00, 0x10,
		0xdf, 0x00, 0x01, 0x11, 0x70,
	})
}

@(test)
test_write_header_rejects_negative_count :: proc(t: ^testing.T) {
	e: msgpack.Encoder
	msgpack.encoder_init(&e)
	defer msgpack.encoder_destroy(&e)
	testing.expect_value(t, msgpack.write_array_header(&e, -1), encode_err(.Invalid_Length))
	testing.expect_value(t, msgpack.write_map_header(&e, -5), encode_err(.Invalid_Length))
	testing.expect_value(t, len(msgpack.encoder_bytes(&e)), 0)
}

@(test)
test_write_ext_uses_fixext_and_ext_formats :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, alloc)
	defer msgpack.encoder_destroy(&e)

	payload: [20]byte
	Case :: struct {
		n:      int,
		header: []byte,
	}
	cases := []Case {
		{1, {0xd4, 0x05}},
		{2, {0xd5, 0x05}},
		{4, {0xd6, 0x05}},
		{8, {0xd7, 0x05}},
		{16, {0xd8, 0x05}},
		{0, {0xc7, 0x00, 0x05}},
		{3, {0xc7, 0x03, 0x05}},
		{17, {0xc7, 0x11, 0x05}},
	}
	for c in cases {
		msgpack.encoder_reset(&e)
		testing.expect_value(t, msgpack.write_ext(&e, 5, payload[:c.n]), nil)
		out := msgpack.encoder_bytes(&e)
		testing.expect_value(t, len(out), len(c.header) + c.n)
		expect_bytes(t, out[:len(c.header)], c.header)
	}

	big := make([]byte, 300, alloc)
	defer delete(big, alloc)
	msgpack.encoder_reset(&e)
	msgpack.write_ext(&e, -2, big)
	expect_bytes(t, msgpack.encoder_bytes(&e)[:4], {0xc8, 0x01, 0x2c, 0xfe})
}

@(test)
test_write_timestamp_layouts :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, alloc)
	defer msgpack.encoder_destroy(&e)

	// 32-bit layout: whole seconds that fit in u32.
	msgpack.write_timestamp(&e, {seconds = 1, nanoseconds = 0})
	expect_bytes(t, msgpack.encoder_bytes(&e), {0xd6, 0xff, 0, 0, 0, 1})

	// 64-bit layout: nanoseconds in the top 30 bits.
	msgpack.encoder_reset(&e)
	msgpack.write_timestamp(&e, {seconds = 1, nanoseconds = 1})
	expect_bytes(t, msgpack.encoder_bytes(&e), {0xd7, 0xff, 0, 0, 0, 0x04, 0, 0, 0, 1})

	// 96-bit layout: negative seconds.
	msgpack.encoder_reset(&e)
	msgpack.write_timestamp(&e, {seconds = -1, nanoseconds = 0})
	expect_bytes(t, msgpack.encoder_bytes(&e), {0xc7, 12, 0xff, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
}

@(test)
test_write_timestamp_rejects_bad_nanoseconds :: proc(t: ^testing.T) {
	e: msgpack.Encoder
	msgpack.encoder_init(&e)
	defer msgpack.encoder_destroy(&e)
	err := msgpack.write_timestamp(&e, {seconds = 0, nanoseconds = 1_000_000_000})
	testing.expect_value(t, err, encode_err(.Bad_Timestamp))
	testing.expect_value(t, len(msgpack.encoder_bytes(&e)), 0)
}

@(test)
test_encoder_reports_allocator_failure :: proc(t: ^testing.T) {
	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, mem.nil_allocator())
	defer msgpack.encoder_destroy(&e)
	err := msgpack.write_str(&e, "hello")
	testing.expect(t, err != nil, "writing through the nil allocator must fail")
}
