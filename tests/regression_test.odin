package msgpack_tests

import msgpack ".."
import "core:mem"
import "core:testing"

Weekday :: enum {
	Mon,
	Tue,
}

// A union variant that marshal writes as bin must unmarshal back into that variant.
@(test)
test_union_with_byte_array_round_trips :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Id :: union {
		string,
		[4]u8,
	}
	src: Id = [4]u8{1, 2, 3, 4}
	data, err := msgpack.marshal(src, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)

	dst: Id
	testing.expect_value(t, msgpack.unmarshal(data, &dst, alloc), nil)
	defer msgpack.destroy(&dst, alloc)
	got, ok := dst.([4]u8)
	testing.expect(t, ok, "bin must select the [4]u8 variant")
	testing.expect_value(t, got, [4]u8{1, 2, 3, 4})
}

// A union variant that marshal writes as an array must unmarshal back, enumerated arrays included.
@(test)
test_union_with_enumerated_array_round_trips :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Hours :: union {
		i64,
		[Weekday]int,
	}
	src: Hours = [Weekday]int{.Mon = 8, .Tue = 6}
	data, err := msgpack.marshal(src, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)

	dst: Hours
	testing.expect_value(t, msgpack.unmarshal(data, &dst, alloc), nil)
	got, ok := dst.([Weekday]int)
	testing.expect(t, ok, "array must select the [Weekday]int variant")
	testing.expect_value(t, got[.Mon], 8)
	testing.expect_value(t, got[.Tue], 6)
}

// A union applies the same lenient conversions as a plain destination when no variant matches exactly.
@(test)
test_union_falls_back_to_lenient_conversions :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Number :: union {
		f64,
		string,
	}
	n: Number
	testing.expect_value(t, msgpack.unmarshal([]byte{0x05}, &n, alloc), nil)
	testing.expect_value(t, n, Number(f64(5)))

	Text :: union {
		bool,
		string,
	}
	s: Text
	testing.expect_value(t, msgpack.unmarshal([]byte{0xc4, 2, 'h', 'i'}, &s, alloc), nil)
	testing.expect_value(t, s, Text("hi"))
	msgpack.destroy(&s, alloc)

	Day :: union {
		bool,
		Weekday,
	}
	d: Day
	testing.expect_value(t, msgpack.unmarshal([]byte{0xa3, 'T', 'u', 'e'}, &d, alloc), nil)
	testing.expect_value(t, d, Day(Weekday.Tue))
}

// An exact match wins over a lenient one, whatever the variant order.
@(test)
test_union_prefers_exact_kind :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Number :: union {
		f64,
		i64,
	}
	n: Number
	testing.expect_value(t, msgpack.unmarshal([]byte{0x05}, &n, alloc), nil)
	testing.expect_value(t, n, Number(i64(5)))

	Stamp :: union {
		msgpack.Extension,
		msgpack.Timestamp,
	}
	ts := []byte{0xd6, 0xff, 0, 0, 0, 10}
	s: Stamp
	testing.expect_value(t, msgpack.unmarshal(ts, &s, alloc), nil)
	defer msgpack.destroy(&s, alloc)
	got, ok := s.(msgpack.Timestamp)
	testing.expect(t, ok, "a timestamp must select the Timestamp variant")
	testing.expect_value(t, got, msgpack.Timestamp{seconds = 10})
}

// Decoding into an Odin map uses only the allocator the caller passes, never context.temp_allocator.
@(test)
test_unmarshal_map_does_not_use_temp_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	temp: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp, context.allocator)
	defer mem.tracking_allocator_destroy(&temp)
	context.temp_allocator = mem.tracking_allocator(&temp)

	// {"a": 1, "b": 2}
	input := []byte{0x82, 0xa1, 'a', 0x01, 0xa1, 'b', 0x02}
	m: map[string]int
	testing.expect_value(t, msgpack.unmarshal(input, &m, alloc), nil)
	defer msgpack.destroy(&m, alloc)
	testing.expect_value(t, m["a"], 1)
	testing.expect_value(t, m["b"], 2)
	testing.expect_value(t, temp.total_allocation_count, 0)
}
