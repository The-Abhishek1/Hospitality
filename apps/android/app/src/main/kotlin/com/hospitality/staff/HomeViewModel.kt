package com.hospitality.staff

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hospitality.staff.data.*
import io.github.jan.supabase.auth.auth
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class HomeState(
    val properties: List<PropertyDto> = emptyList(),
    val propertyId: String? = null,
    val tasks: List<TaskDto> = emptyList(),
    val units: List<UnitDto> = emptyList(),
    val loading: Boolean = false,
    val message: String? = null,
)

class HomeViewModel(private val repo: StaffRepository = StaffRepository()) : ViewModel() {
    val state = MutableStateFlow(HomeState())
    val userId: String? get() = Backend.client.auth.currentUserOrNull()?.id

    init { loadProperties() }

    private fun loadProperties() = launchSafely {
        val props = repo.properties()
        state.update { it.copy(properties = props, propertyId = props.firstOrNull()?.id) }
        refreshNow()
    }

    fun selectProperty(id: String) { state.update { it.copy(propertyId = id) }; refresh() }
    fun refresh() = launchSafely { refreshNow() }

    private suspend fun refreshNow() {
        val pid = state.value.propertyId ?: return
        val tasks = repo.openTasks(pid)
        val units = repo.units(pid)
        state.update { it.copy(tasks = tasks, units = units) }
    }

    fun claim(id: String) = launchSafely { repo.claim(id); refreshNow() }
    fun setStatus(id: String, status: String) = launchSafely { repo.setStatus(id, status); refreshNow() }
    fun dismissMessage() = state.update { it.copy(message = null) }

    // Database rules are the source of truth; surface their message instead of re-implementing them here.
    private fun launchSafely(block: suspend () -> Unit) = viewModelScope.launch {
        state.update { it.copy(loading = true) }
        try { block() } catch (e: Exception) { state.update { s -> s.copy(message = e.message ?: "Something went wrong") } }
        finally { state.update { it.copy(loading = false) } }
    }
}
