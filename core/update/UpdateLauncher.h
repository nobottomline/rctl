#pragma once

// Starts the package-external updater and returns a malloc-owned JSON response.
char *rctl_update_launch(const char *manifest_url, int *status);
char *rctl_update_status(void);
