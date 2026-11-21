package com.hospitality.staff.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.hospitality.staff.HomeViewModel
import com.hospitality.staff.data.TaskDto
import com.hospitality.staff.data.UnitDto

private val TABS = listOf("My tasks", "Unassigned", "Rooms")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(onSignOut: () -> Unit, vm: HomeViewModel = viewModel()) {
    val s by vm.state.collectAsStateWithLifecycle()
    var tab by remember { mutableIntStateOf(0) }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(s.message) { s.message?.let { snackbar.showSnackbar(it); vm.dismissMessage() } }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text(s.properties.firstOrNull { it.id == s.propertyId }?.name ?: "Staff") },
                actions = {
                    TextButton(onClick = vm::refresh) { Text("Refresh") }
                    TextButton(onClick = onSignOut) { Text("Sign out") }
                },
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad)) {
            if (s.properties.size > 1) {
                Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    s.properties.forEach { p ->
                        FilterChip(selected = p.id == s.propertyId, onClick = { vm.selectProperty(p.id) }, label = { Text(p.name) })
                    }
                }
            }
            TabRow(selectedTabIndex = tab) {
                TABS.forEachIndexed { i, t -> Tab(selected = tab == i, onClick = { tab = i }, text = { Text(t) }) }
            }
            if (s.loading) LinearProgressIndicator(Modifier.fillMaxWidth())

            when (tab) {
                0 -> TaskList(s.tasks.filter { it.assigneeId != null && it.assigneeId == vm.userId }, "Nothing assigned to you.", vm)
                1 -> TaskList(s.tasks.filter { it.assigneeId == null }, "No unassigned tasks.", vm)
                else -> RoomList(s.units)
            }
        }
    }
}

@Composable
private fun TaskList(tasks: List<TaskDto>, empty: String, vm: HomeViewModel) {
    if (tasks.isEmpty()) { Box(Modifier.fillMaxSize(), Alignment.Center) { Text(empty) }; return }
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(tasks, key = { it.id }) { t ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Text(t.title, style = MaterialTheme.typography.titleMedium)
                    Text("${t.priority} · ${t.kind} · ${t.status}", style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (t.assigneeId == null) Button(onClick = { vm.claim(t.id) }) { Text("Claim") }
                        if (t.assigneeId != null && t.status == "open") Button(onClick = { vm.setStatus(t.id, "in_progress") }) { Text("Start") }
                        if (t.assigneeId != null && t.status == "in_progress") Button(onClick = { vm.setStatus(t.id, "done") }) { Text("Done") }
                    }
                }
            }
        }
    }
}

@Composable
private fun RoomList(units: List<UnitDto>) {
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items(units, key = { it.id }) { u ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(u.name, style = MaterialTheme.typography.titleMedium)
                Text(u.housekeepingStatus.replace('_', ' '))
            }
            HorizontalDivider()
        }
    }
}
