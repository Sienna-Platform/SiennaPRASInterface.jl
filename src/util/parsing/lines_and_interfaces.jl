"""
    get_sorted_region_tuples(lines::Vector{PSY.Branch}, region_names::Vector{String})

Get sorted (reg_from, reg_to) tuples of inter-regional lines.
"""
function get_sorted_region_tuples(
    lines::Vector{PSY.Branch},
    region_names::Vector{String},
    aggregation::Type{T},
) where {T <: PSY.AggregationTopology}
    region_idxs = Dict(name => idx for (idx, name) in enumerate(region_names))

    line_from_to_reg_idxs = similar(lines, Tuple{Int, Int})

    for (l, line) in enumerate(lines)
        from_name =
            PSY.get_name(get_aggregation_function(aggregation)(PSY.get_from_bus(line)))
        to_name = PSY.get_name(get_aggregation_function(aggregation)(PSY.get_to_bus(line)))

        from_idx = region_idxs[from_name]
        to_idx = region_idxs[to_name]

        line_from_to_reg_idxs[l] =
            from_idx < to_idx ? (from_idx, to_idx) : (to_idx, from_idx)
    end

    return line_from_to_reg_idxs
end

"""
    get_sorted_lines(lines::Vector{PSY.Branch}, region_names::Vector{String})

Get sorted lines, interface region indices, and interface line indices.

# Arguments

  - `lines::Vector{PSY.Branch}`: Lines
  - `region_names::Vector{String}`: Region names

# Returns

  - `sorted_lines::Vector{PSY.Branch}`: Sorted lines
  - `interface_reg_idxs::Vector{Tuple{Int, Int}}`: Interface region indices
  - `interface_line_idxs::Vector{UnitRange{Int}}`: Interface line indices
"""
function get_sorted_lines(
    lines::Vector{PSY.Branch},
    region_names::Vector{String},
    aggregation::Type{T},
) where {T <: PSY.AggregationTopology}
    line_from_to_reg_idxs = get_sorted_region_tuples(lines, region_names, aggregation)
    line_ordering = sortperm(line_from_to_reg_idxs)

    sorted_lines = lines[line_ordering]
    sorted_from_to_reg_idxs = line_from_to_reg_idxs[line_ordering]
    interface_reg_idxs = unique(sorted_from_to_reg_idxs)

    # Ref tells Julia to use interfaces as Vector, only broadcasting over
    # lines_sorted
    interface_line_idxs = searchsorted.(Ref(sorted_from_to_reg_idxs), interface_reg_idxs)

    return sorted_lines, interface_reg_idxs, interface_line_idxs
end
