# Software project search implementation plan

1. Use the same label, status and text predicates for project listing and counting in `Singularity.Knowledge`. Determine the availability of the next page from the count.
2. Arrange the existing controls in a responsive search toolbar in `KnowledgeLive.Index`. Render the count, active label, reset link and empty state using the current LiveView route and the knowledge gettext domain.
3. Update the shared `ItemComponents.project_table/1` to allocate space to the repository name and description, group exceptional states with the project, and disclose extra labels. Adapt the same table rows to narrow screens.
4. Exercise filtered counts, pagination boundaries, reset and label visibility with LiveView tests. Extract translations and run formatting, strict test compilation and the umbrella suite. Inspect populated desktop and phone views in the local devenv server.
