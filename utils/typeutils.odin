package utils

import "core:reflect"


variant_is :: proc(it : $TVariant, $T : typeid) -> bool {
    return reflect.union_variant_typeid(it) == T;
}
type_of_variant :: proc(it : $TVariant) -> typeid {
    return reflect.union_variant_typeid(it);
}