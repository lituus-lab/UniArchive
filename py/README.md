# UniArchive Python binding

The Cython extension exposes bounded ZIP entry counting, ordered names,
verified entry reads, and transactional extraction through the versioned
`uar_` C ABI. `create(output, inputs, store=False)` recursively creates a new
archive, while `extract(..., selectors=[...])` limits extraction to the union
of exact files and directory subtrees.
