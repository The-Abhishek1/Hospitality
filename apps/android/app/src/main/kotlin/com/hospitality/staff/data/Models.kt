package com.hospitality.staff.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class PropertyDto(val id: String, val name: String)

@Serializable
data class TaskDto(
    val id: String,
    val title: String,
    val kind: String,
    val status: String,
    val priority: String,
    @SerialName("assignee_id") val assigneeId: String? = null,
    @SerialName("due_at") val dueAt: String? = null,
)

@Serializable
data class UnitDto(
    val id: String,
    val name: String,
    @SerialName("housekeeping_status") val housekeepingStatus: String,
)
