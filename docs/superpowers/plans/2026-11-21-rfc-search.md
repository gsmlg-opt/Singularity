# RFC search implementation plan

1. Extract the project index's search toolbar into a shared Phoenix component. Pass the localized title, placeholder and count from each index. Keep the project sort and status controls in an optional slot.
2. Use the toolbar and responsive results table on the RFC index. Link an existing automatic status label to its filter, preserve the query and return to the first page when filtering.
3. Exercise counts, label removal, combined search and reset in LiveView tests. Extract gettext strings, run formatting, strict test compilation and the suite, and inspect populated desktop and mobile results in both themes.
