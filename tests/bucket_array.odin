package tests

import "../utils"

import "core:testing"
import "core:runtime"
import "core:fmt"
import "core:time"
import "core:math/rand"



// Unit tests make me puke from boredom so I just asked chatgpt to do it.

@(test)
append :: proc(t : ^testing.T) {

    context = runtime.default_context();

    arr := utils.make_bucket_array(int, 12);
    defer utils.delete_bucket_array(&arr);

    for i in 0..<221 {
        p := utils.bucket_array_append(&arr, i);
        testing.expectf(t, p^ == i, "Unexpected return from append(): appended %i, but returned %i", i, p^);
    }
    for i in 0..<221 {
        testing.expectf(t, utils.bucket_array_get(&arr, i) == i, "Node at index %i does not point to same value as first appended. Expected %i, got %i.", i, i, utils.bucket_array_get(&arr, i));
    }
}

@(test)
remove :: proc(t : ^testing.T) {

    context = runtime.default_context();

    arr := utils.make_bucket_array(int, 12);
    defer utils.delete_bucket_array(&arr);

    expect_len :: proc(t : ^testing.T, arr : utils.Bucket_Array($T, $N), the_len : int) {
        testing.expect_value(t, utils.bucket_array_len(arr), the_len);
    }

    utils.bucket_array_append(&arr, 0);
    utils.bucket_array_append(&arr, 1);
    utils.bucket_array_append(&arr, 2);
    utils.bucket_array_append(&arr, 3);
    utils.bucket_array_append(&arr, 4);
    expect_len(t, arr, 5);

    utils.bucket_array_ordered_remove(&arr, 2);
    expect_len(t, arr, 4);

    testing.expect_value(t, utils.bucket_array_get(&arr, 2), 3);

    utils.bucket_array_unordered_remove(&arr, 1);
    expect_len(t, arr, 3);

    testing.expect_value(t, utils.bucket_array_get(&arr, 1), 4);

    nine := 9;
    p := utils.bucket_array_append(&arr, nine);
    testing.expect_value(t, p^, nine);

    expect_len(t, arr, 4);
}

@(test)
high_volume_insertions :: proc(t : ^testing.T) {
    arr := utils.make_bucket_array(int, 128); // Use the default bucket capacity
    defer utils.delete_bucket_array(&arr);

    num_elements := 10000
    for i in 0..<num_elements {
        p := utils.bucket_array_append(&arr, i);
        testing.expectf(t, p^ == i, "High volume insertion failed at index %i", i);
    }

    for i in 0..<num_elements {
        value := utils.bucket_array_get(&arr, i);
        testing.expectf(t, value == i, "Incorrect value after high volume insertions. Expected %i, got %i.", i, value);
    }

    testing.expect_value(t, utils.bucket_array_len(arr), num_elements);
}

@(test)
random_insertions_and_removals :: proc(t : ^testing.T) {
    arr := utils.make_bucket_array(int, 50); // Smaller bucket size to trigger more reallocations
    defer utils.delete_bucket_array(&arr);

    insertions := 500
    removals := 200
    for i in 0..<insertions {
        utils.bucket_array_append(&arr, cast(int)rand.float32_range(0, 1000));
    }

    for i in 0..<removals {
        index_to_remove := cast(int)rand.float32_range(0, cast(f32)utils.bucket_array_len(arr));
        utils.bucket_array_unordered_remove(&arr, index_to_remove);
    }

    final_count := insertions - removals
    testing.expect_value(t, utils.bucket_array_len(arr), final_count);
}

@(test)
edge_cases :: proc(t : ^testing.T) {
    arr := utils.make_bucket_array(int, 10);
    defer utils.delete_bucket_array(&arr);

    // Edge Case: Append until resize
    for i in 0..<15 { // Greater than bucket capacity to force a resize
        utils.bucket_array_append(&arr, i);
    }
    testing.expect_value(t, utils.bucket_array_len(arr), 15);

    // Edge Case: Access boundary element
    last_val := utils.bucket_array_get(&arr, 14);
    testing.expect_value(t, last_val, 14);

    // Clean up by removing all
    for i:=14; i>= 0; i -= 1 {
        utils.bucket_array_unordered_remove(&arr, i);
    }
    testing.expect_value(t, utils.bucket_array_len(arr), 0);
}

@(test)
correct_behavior_after_removals :: proc(t : ^testing.T) {
    arr := utils.make_bucket_array(int, 5); // Small bucket size for easier testing
    defer utils.delete_bucket_array(&arr);

    // Append and then remove in various ways
    for i in 0..<5 {
        utils.bucket_array_append(&arr, i);
    }

    // Ordered removal
    utils.bucket_array_ordered_remove(&arr, 1); // Removes '1'
    testing.expect_value(t, utils.bucket_array_get(&arr, 1), 2);

    // Unordered removal
    utils.bucket_array_unordered_remove(&arr, 2); // This should move last element to position 2
    testing.expect_value(t, utils.bucket_array_len(arr), 3);

    // Append after removals
    for i in 5..<7 {
        utils.bucket_array_append(&arr, i);
    }
    testing.expect_value(t, utils.bucket_array_len(arr), 5);
}

@(test)
append_and_multiple_removals :: proc(t : ^testing.T) {
    context = runtime.default_context();
    arr := utils.make_bucket_array(int, 10);
    defer utils.delete_bucket_array(&arr);

    for i in 0..<20 {
        utils.bucket_array_append(&arr, i);
    }
    testing.expect_value(t, utils.bucket_array_len(arr), 20);

    for i in 0..<10 {
        utils.bucket_array_ordered_remove(&arr, 0);
    }
    testing.expect_value(t, utils.bucket_array_len(arr), 10);

    for i in 0..<10 {
        value := utils.bucket_array_get(&arr, i);
        testing.expectf(t, value == i + 10, "Incorrect value after multiple removals. Expected %i, got %i.", i + 10, value);
    }
}
