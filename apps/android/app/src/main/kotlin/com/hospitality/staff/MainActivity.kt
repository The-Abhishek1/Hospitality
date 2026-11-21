package com.hospitality.staff

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.hospitality.staff.ui.HomeScreen
import com.hospitality.staff.ui.LoginScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { Surface(Modifier.fillMaxSize()) { Root() } } }
    }
}

@Composable
fun Root(session: SessionViewModel = viewModel()) {
    val state by session.state.collectAsStateWithLifecycle()
    when (state) {
        AuthState.Loading -> Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
        AuthState.SignedOut -> LoginScreen(session)
        AuthState.SignedIn -> HomeScreen(onSignOut = session::signOut)
    }
}
