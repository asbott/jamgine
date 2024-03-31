package utils

import "core:mem"
import "core:fmt"

DEFAULT_BUCKET_CAP :: 128

Bucket :: struct($T : typeid, $CAP : int) {
    pool : [CAP]struct #raw_union { item : T, next_free_index : int },
    occupied_flags : [CAP]bool,
}

Bucket_Node :: struct($T : typeid) {
    index : int,
}

Bucket_Array :: struct($T : typeid, $BUCKET_CAP := DEFAULT_BUCKET_CAP) {
    buckets : [dynamic]^Bucket(T, BUCKET_CAP),
    nodes : [dynamic]Bucket_Node(T),
    total_count : int,

    next_free_index : int,
    allocator : mem.Allocator,
}

@(private)
init_bucket :: proc(bucket : ^Bucket($T, $N)) {
    for _,i in bucket.pool {
        bucket.pool[i].next_free_index = -1;
    }
}

make_bucket_array_custom_cap :: proc($T : typeid, $BUCKET_CAP : int, allocator := context.allocator) -> (arr : Bucket_Array(T, BUCKET_CAP)) {
    arr.allocator = allocator;

    arr.buckets = make(type_of(arr.buckets), 1);
    for _,i in arr.buckets {
        arr.buckets[i] = new(Bucket(T, BUCKET_CAP));
        init_bucket(arr.buckets[i]);
    }
    
    arr.nodes = make(type_of(arr.nodes));

    return;
}
make_bucket_array_default_cap :: proc($T : typeid, allocator := context.allocator) -> Bucket_Array(T) {
    return make_bucket_array_custom_cap(T, DEFAULT_BUCKET_CAP, allocator);
}
make_bucket_array :: proc {
    make_bucket_array_custom_cap,
    make_bucket_array_default_cap,
}

delete_bucket_array :: proc(using arr : ^Bucket_Array($T, $N)) {
    delete(nodes);

    for bucket in buckets {
        free(bucket);
    }
    delete(buckets);
}

bucket_array_get_ptr :: proc(using arr : ^Bucket_Array($T, $N), index : int) -> ^T {
    assert(index < len(nodes) && index >= 0, "Bucket array index out of range");

    node := &nodes[index];

    bucket_index := node.index / N;
    index_in_bucket := node.index % N;

    bucket := buckets[bucket_index];

    assert(bucket.occupied_flags[index_in_bucket]);

    return &bucket.pool[index_in_bucket].item;
}
bucket_array_get :: proc(using arr : ^Bucket_Array($T, $N), index : int) -> T {
    return bucket_array_get_ptr(arr, index)^;
}

bucket_array_append_empty :: proc(using arr : ^Bucket_Array($T, $N)) -> ^T{
    context.allocator = arr.allocator;

    bucket_index := next_free_index / N;

    if bucket_index >= len(buckets) {
        new_bucket := new(Bucket(T, N));
        init_bucket(new_bucket);
        append(&buckets, new_bucket);
    }
    assert(bucket_index < len(buckets));

    index_in_bucket := next_free_index % N;

    bucket := buckets[bucket_index];
    assert(!bucket.occupied_flags[index_in_bucket])
    bucket.occupied_flags[index_in_bucket] = true;

    item := &bucket.pool[index_in_bucket];

    total_count += 1;
    append(&nodes, Bucket_Node(T){next_free_index});

    if item.next_free_index >= 0 {
        next_free_index = item.next_free_index;
    } else {
        next_free_index += 1;
    }

    // Zero memory
    item.item = {};

    return &bucket.pool[index_in_bucket].item;
}
bucket_array_append_elem :: proc(using arr : ^Bucket_Array($T, $N), elem : T) -> ^T {
    p := bucket_array_append_empty(arr);
    p^ = elem;
    return p;
}
bucket_array_append :: proc {
    bucket_array_append_empty,
    bucket_array_append_elem,
}
@(private)
bucket_array_unoccupy :: proc(using arr : ^Bucket_Array($T, $N), index : int) {
    context.allocator = arr.allocator;

    assert(index < len(nodes) && index >= 0, "Bucket array index out of range");

    node := nodes[index];

    bucket_index := node.index / N;
    index_in_bucket := node.index % N;

    
    buckets[bucket_index].occupied_flags[index_in_bucket] = false;

    item := &buckets[bucket_index].pool[index_in_bucket];

    item.next_free_index = next_free_index;

    next_free_index = node.index;

    total_count -= 1;
}
bucket_array_ordered_remove :: proc(using arr : ^Bucket_Array($T, $N), index : int) {
    context.allocator = arr.allocator;

    bucket_array_unoccupy(arr, index);

    ordered_remove(&nodes, index);
}
bucket_array_unordered_remove :: proc(using arr : ^Bucket_Array($T, $N), index : int) {
    context.allocator = arr.allocator;

    bucket_array_unoccupy(arr, index);

    unordered_remove(&nodes, index);
}

bucket_array_len :: proc(arr : Bucket_Array($T, $N)) -> int {
    return arr.total_count;
}