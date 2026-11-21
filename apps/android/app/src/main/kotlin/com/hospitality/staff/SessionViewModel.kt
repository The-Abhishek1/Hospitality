package com.hospitality.staff

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hospitality.staff.data.Backend
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

enum class AuthState { Loading, SignedOut, SignedIn }

class SessionViewModel : ViewModel() {
    private val auth = Backend.client.auth

    val state: StateFlow<AuthState> = auth.sessionStatus.map {
        when (it) {
            is SessionStatus.Authenticated -> AuthState.SignedIn
            is SessionStatus.NotAuthenticated -> AuthState.SignedOut
            else -> AuthState.Loading
        }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, AuthState.Loading)

    val error = MutableStateFlow<String?>(null)
    val busy = MutableStateFlow(false)

    fun signIn(email: String, password: String) = viewModelScope.launch {
        busy.value = true; error.value = null
        try {
            auth.signInWith(Email) { this.email = email.trim(); this.password = password }
        } catch (e: Exception) {
            error.value = e.message ?: "Sign-in failed"
        } finally {
            busy.value = false
        }
    }

    fun signOut() = viewModelScope.launch { runCatching { auth.signOut() } }
}
