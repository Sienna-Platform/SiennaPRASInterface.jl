mutable struct PowerFlowEvaluationData{T <: PFS.PowerFlowContainer}
    power_flow_data::T
    input_key_map::Dict
    is_solved::Bool
end

function write_output_to_pf_data!(pf_data, dispatchproblem::PRASCore.DispatchProblem)
return
end
