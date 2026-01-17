# ADR-0004: Map Support with Pluggable Implementations

## Status

Proposed

## Context

Protocol Buffers support map fields (`map<K, V>`) which are syntactic sugar for repeated message fields with key/value entries. proto-zig currently has `Mode.map = 2` defined in `mini_table.zig` but no actual map handling implementation.

Different use cases require different map implementations:
- **ArrayHashMap**: Preserves insertion order, good for deterministic encoding
- **HashMap**: Better performance for large maps, no order guarantees
- **Custom implementations**: Users may have specific requirements (e.g., bounded maps)

## Decision

Implement map support with compile-time pluggable map implementations using Zig's generic programming.

### Components Modified

- **src/map.zig**: New file with MapField storage type and DefaultMap
- **src/message.zig**: Add get_map() accessor
- **src/wire/decode.zig**: Public generic Decoder struct parameterized by map type
- **src/wire/encode.zig**: Public generic Encoder struct parameterized by map type
- **src/proto.zig**: Export map types and generic encoder/decoder
- **src/codegen/descriptor_parser.zig**: Parse map_entry option from MessageOptions
- **src/codegen/layout.zig**: Handle MapField size calculation

### Architecture

```
                    ┌─────────────────┐
                    │  User Chooses   │
                    │   Map Type      │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
    ┌──────────────────┐        ┌──────────────────┐
    │ DefaultDecoder   │        │ CustomDecoder    │
    │ (ArrayHashMap)   │        │ (HashMap, etc)   │
    └────────┬─────────┘        └────────┬─────────┘
             │                           │
             ▼                           ▼
    ┌──────────────────────────────────────────────┐
    │                  Message                      │
    │  ┌─────────────────────────────────────────┐ │
    │  │ MapField { ptr, key_type, value_type }  │ │
    │  │         ↓                               │ │
    │  │    *Map(K, V) (arena-allocated)         │ │
    │  └─────────────────────────────────────────┘ │
    └──────────────────────────────────────────────┘
```

### Wire Format

Maps are encoded as repeated submessages on the wire:

```
message MapEntry {
  K key = 1;
  V value = 2;
}
```

The decoder recognizes `mode == .map` and routes to map-specific handling instead of treating it as a regular repeated field.

### Duck-Typed Map Interface

Any map type can be used if it satisfies this interface (checked at comptime):

```zig
fn put(self: *Map, allocator: Allocator, key: K, value: V) Allocator.Error!void
fn get(self: *const Map, key: K) ?V
fn count(self: *const Map) usize
fn iterator(self: *const Map) Iterator  // Iterator has next() -> ?Entry
```

This allows using `std.ArrayHashMapUnmanaged`, `std.HashMapUnmanaged`, or custom implementations.

### Map Storage in Message

```
Message.data layout:
┌───────────────────────────┐
│ hasbits (presence bits)   │  offset 0
├───────────────────────────┤
│ oneof case tags           │  offset hasbit_bytes
├───────────────────────────┤
│ field_1: i32              │  scalar stored directly
├───────────────────────────┤
│ field_2: RepeatedField    │  repeated: {data, count, capacity, element_size}
├───────────────────────────┤
│ field_3: MapField         │  map: {ptr, key_type, value_type}
└───────────────────────────┘
```

### API Design

```zig
// Simple: use convenience function (default ArrayHashMap)
try proto.decode(data, msg, &arena, .{});

// Explicit: create decoder with custom map type
const HashMapDecoder = proto.Decoder(std.HashMapUnmanaged);
var decoder = HashMapDecoder.init(&arena);
try decoder.decode(data, msg, .{});

// Accessing maps
const map_field = msg.get_map(&my_map_field);
const map = map_field.getTyped(proto.DefaultMap(i32, proto.StringView));
if (map.get(42)) |value| {
    // use value
}
```

## Consequences

### Positive

- Zero runtime overhead (compile-time generics)
- User can choose optimal map implementation for their use case
- Backwards compatible (convenience functions use sensible defaults)
- Type-safe access to map fields
- Follows Zig zen: explicit over implicit

### Negative

- Encoder/Decoder must use same map type (type mismatch = runtime error)
- Slightly more complex API for custom map types
- Generated code must specify map type at compile time

### Risks

- Map key/value type combinations create many instantiations (compile time)
- Arena allocation strategy may not suit all map implementations

## Implementation Plan

1. Create `src/map.zig` with MapField, DefaultMap, HashContext
2. Add get_map() accessor to Message
3. Make Decoder a public generic struct parameterized by map type
4. Make Encoder a public generic struct with matching map type
5. Export map types in proto.zig
6. Update codegen to parse map_entry option and set mode=.map
7. Add unit tests and round-trip tests
8. Add to differential testing against upb

## References

- upb map implementation: `/home/bits/gh/google/protobuf/upb/message/map.h`
- Protobuf map encoding: https://protobuf.dev/programming-guides/proto3/#maps
- Zig std.ArrayHashMap: `/usr/lib/zig/std/array_hash_map.zig`
