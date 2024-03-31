package entities

import "jamgine:utils"

Entity_Type :: struct($TVariant : typeid, $TData : typeid) {
    using base_data : TData,
    despawn_flag : bool,
    variant : TVariant,
}

Entity_Manager :: struct($TEntity : typeid) {
    data : utils.Bucket_Array(TEntity),
    entities : [dynamic]^TEntity,
}

init_entity_manager :: proc(mgr : ^Entity_Manager($TEntity)) {
    mgr.data = utils.make_bucket_array(TEntity);
    mgr.entities = make([dynamic]^TEntity);
}
destroy_entity_manager :: proc(mgr : ^Entity_Manager($TEntity)) {
    delete(mgr.entities);
    utils.delete_bucket_array(&mgr.data);
}


spawn :: proc(mgr : ^Entity_Manager($TEntity), $TVariant : typeid) -> ^TVariant {
    entity := utils.bucket_array_append_empty(&mgr.data);
    entity.variant = TVariant{};
    variant := &entity.variant.(TVariant);
    variant.base = entity;

    append(&mgr.entities, entity);

    return variant;
}

purge :: proc(mgr : ^Entity_Manager($TEntity)) {
    for i := len(mgr.entities)-1; i >= 0; i -= 1 {
        if mgr.entities[i].despawn_flag {
            unordered_remove(&mgr.entities, i);
            utils.bucket_array_unordered_remove(&mgr.data, i);
        }
    }
}