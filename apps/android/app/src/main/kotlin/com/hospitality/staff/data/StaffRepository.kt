package com.hospitality.staff.data

import com.hospitality.staff.BuildConfig
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

object Backend {
    // Only the anon key lives in the app. Authorization is enforced by RLS and the database functions.
    val client: SupabaseClient = createSupabaseClient(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY) {
        install(Auth)
        install(Postgrest)
    }
}

class StaffRepository(private val db: SupabaseClient = Backend.client) {

    suspend fun properties(): List<PropertyDto> =
        db.from("properties").select(Columns.list("id", "name")) { order("name", Order.ASCENDING) }.decodeList()

    suspend fun openTasks(propertyId: String): List<TaskDto> =
        db.from("tasks")
            .select(Columns.list("id", "title", "kind", "status", "priority", "assignee_id", "due_at")) {
                filter {
                    eq("property_id", propertyId)
                    isIn("status", listOf("open", "in_progress"))
                }
                order("created_at", Order.DESCENDING)
            }.decodeList()

    suspend fun units(propertyId: String): List<UnitDto> =
        db.from("accommodation_units")
            .select(Columns.list("id", "name", "housekeeping_status")) {
                filter { eq("property_id", propertyId); eq("active", true) }
                order("name", Order.ASCENDING)
            }.decodeList()

    suspend fun claim(taskId: String) {
        db.postgrest.rpc("claim_task", buildJsonObject { put("p_id", taskId) })
    }

    suspend fun setStatus(taskId: String, status: String) {
        db.postgrest.rpc("set_task_status", buildJsonObject { put("p_id", taskId); put("p_status", status) })
    }
}
