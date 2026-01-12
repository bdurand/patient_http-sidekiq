// frozen_string_literal: true
// Async HTTP Dashboard

// Colors for capacity bar
const chartColors = {
  primary: '#00a0ff',    // Brand blue
  success: '#22c55e',    // Green
  error: '#ef4444',      // Red
  warning: '#f59e0b'     // Amber
};

/**
 * Update all async HTTP statistics
 */
async function updateAsyncHttpStats() {
  try {
    // Construct the API URL using the current root path
    const rootPath = window.location.pathname.split('/sidekiq/')[0] || '';
    const apiUrl = rootPath + '/sidekiq/api/async-http/stats';

    const response = await fetch(apiUrl, {
      headers: {
        'Accept': 'application/json'
      }
    });

    if (!response.ok) {
      console.error('Failed to fetch stats:', response.status);
      return;
    }

    const data = await response.json();
    updateStatsCards(data);
    updateCapacityMetrics(data);
    updateProcessList(data);
  } catch (error) {
    console.error('Error updating async HTTP stats:', error);
  }
}

/**
 * Update summary stat cards
 */
function updateStatsCards(data) {
  const totalRequests = data.totals.requests || 0;
  const avgDuration = totalRequests > 0
    ? Math.round((data.totals.duration || 0) / totalRequests * 1000)
    : 0;

  document.getElementById('total-requests').textContent = formatNumber(totalRequests);
  document.getElementById('avg-duration').textContent = avgDuration + 'ms';
  document.getElementById('total-errors').textContent = formatNumber(data.totals.errors || 0);
  document.getElementById('total-refused').textContent = formatNumber(data.totals.refused || 0);
}

/**
 * Update capacity metrics and progress bar
 */
function updateCapacityMetrics(data) {
  const maxCapacity = data.max_capacity || 0;
  const currentInflight = data.current_inflight || 0;
  const utilization = maxCapacity > 0 ? (currentInflight / maxCapacity * 100).toFixed(1) : 0;

  document.getElementById('max-capacity').textContent = formatNumber(maxCapacity);
  document.getElementById('current-inflight').textContent = formatNumber(currentInflight);
  document.getElementById('utilization-percent').textContent = utilization + '%';

  // Update capacity bar
  const barFill = document.getElementById('capacity-bar-fill');
  barFill.style.width = utilization + '%';

  // Color the bar based on utilization
  if (utilization < 50) {
    barFill.style.background = `linear-gradient(to right, ${chartColors.success}, ${chartColors.primary})`;
  } else if (utilization < 80) {
    barFill.style.background = `linear-gradient(to right, ${chartColors.warning}, ${chartColors.primary})`;
  } else {
    barFill.style.background = `linear-gradient(to right, ${chartColors.error}, ${chartColors.warning})`;
  }
}

/**
 * Update process breakdown table
 */
function updateProcessList(data) {
  const processList = document.getElementById('process-list');
  if (!processList) return;

  const processes = data.processes || {};

  if (Object.keys(processes).length === 0) {
    processList.innerHTML = '<tr class="empty-state"><td colspan="4">No active processes</td></tr>';
    return;
  }

  const rows = Object.entries(processes)
    .map(([processId, info]) => {
      const utilization = info.max_capacity > 0
        ? (info.inflight / info.max_capacity * 100).toFixed(1)
        : 0;
      return `
        <tr>
          <td>${escapeHtml(processId)}</td>
          <td>${formatNumber(info.inflight)}</td>
          <td>${formatNumber(info.max_capacity)}</td>
          <td>${utilization}%</td>
        </tr>
      `;
    });

  processList.innerHTML = rows.join('');
}

/**
 * Format number with thousand separators
 */
function formatNumber(num) {
  if (typeof num === 'string') {
    num = parseFloat(num);
  }
  if (isNaN(num)) return '0';
  return num.toLocaleString('en-US', { maximumFractionDigits: 0 });
}

/**
 * Escape HTML special characters
 */
function escapeHtml(text) {
  const map = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  };
  return text.replace(/[&<>"']/g, m => map[m]);
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
  updateAsyncHttpStats();
  // Auto-refresh every 5 seconds
  setInterval(updateAsyncHttpStats, 5000);
});
