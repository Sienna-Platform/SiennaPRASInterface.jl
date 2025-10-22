"""
Cost curve evaluation utilities for computing total cost and marginal cost.

This module provides functions to evaluate PowerSystems/InfrastructureSystems cost curves
at specific power setpoints. The approach is to:
1. Convert all ValueCurve types to InputOutputCurve using IS built-in conversions
2. Evaluate the InputOutputCurve at the desired power level
3. Apply fuel pricing and VOM costs for ProductionVariableCostCurve types
4. Compute average cost = total_cost / power as marginal cost estimate
"""

using PowerSystems
const PSY = PowerSystems
const IS = PSY.InfrastructureSystems

"""
    evaluate_function_data(func_data::IS.LinearFunctionData, x::Float64)

Evaluate linear function: f(x) = proportional_term * x + constant_term
"""
function evaluate_function_data(func_data::IS.LinearFunctionData, x::Float64)
    return IS.get_proportional_term(func_data) * x + IS.get_constant_term(func_data)
end

"""
    evaluate_function_data(func_data::IS.QuadraticFunctionData, x::Float64)

Evaluate quadratic function: f(x) = quadratic_term * x^2 + proportional_term * x + constant_term
"""
function evaluate_function_data(func_data::IS.QuadraticFunctionData, x::Float64)
    a = IS.get_quadratic_term(func_data)
    b = IS.get_proportional_term(func_data)
    c = IS.get_constant_term(func_data)
    return a * x^2 + b * x + c
end

"""
    evaluate_function_data(func_data::IS.PiecewiseLinearData, x::Float64)

Evaluate piecewise linear function by linear interpolation between points.

If x is outside the curve domain, extrapolate using the slope of the first/last segment.
"""
function evaluate_function_data(func_data::IS.PiecewiseLinearData, x::Float64)
    points = IS.get_points(func_data)

    x_coords = [p.x for p in points]
    y_coords = [p.y for p in points]

    # Handle extrapolation below lower bound
    if x < first(x_coords)
        # Extrapolate using slope of first segment
        x1, x2 = x_coords[1], x_coords[2]
        y1, y2 = y_coords[1], y_coords[2]
        slope = (y2 - y1) / (x2 - x1)
        return y1 + slope * (x - x1)
    end

    # Handle extrapolation above upper bound
    if x > last(x_coords)
        # Extrapolate using slope of last segment
        n = length(x_coords)
        x1, x2 = x_coords[n - 1], x_coords[n]
        y1, y2 = y_coords[n - 1], y_coords[n]
        slope = (y2 - y1) / (x2 - x1)
        return y2 + slope * (x - x2)
    end

    # Find the segment containing x
    i_leq = findlast(<=(x), x_coords)

    # If exactly on the last point, return that point's value
    if i_leq == length(x_coords)
        return y_coords[end]
    end

    # Linear interpolation between points
    x1, x2 = x_coords[i_leq], x_coords[i_leq + 1]
    y1, y2 = y_coords[i_leq], y_coords[i_leq + 1]

    slope = (y2 - y1) / (x2 - x1)
    return y1 + slope * (x - x1)
end

"""
    evaluate_value_curve(curve::IS.ValueCurve, active_power::Float64)

Evaluate any ValueCurve type at given power to get total cost in natural units.

Converts IncrementalCurve and AverageRateCurve to InputOutputCurve using
InfrastructureSystems built-in conversions, then evaluates.
"""
function evaluate_value_curve(curve::IS.ValueCurve, active_power::Float64)
    isapprox(active_power, 0.0) && return 0.0

    # Convert to InputOutputCurve if needed
    input_output_curve = if curve isa IS.InputOutputCurve
        curve
    else
        # Use IS built-in conversion from Incremental/AverageRate to InputOutput
        IS.InputOutputCurve(curve)
    end

    # Evaluate the InputOutputCurve
    func_data = IS.get_function_data(input_output_curve)
    return evaluate_function_data(func_data, active_power)
end

# =============================================================================
# Layer 3: ProductionVariableCostCurve Evaluation (with pricing)
# =============================================================================

"""
    evaluate_production_cost(cost_curve::PSY.CostCurve, active_power::Float64)

Evaluate a CostCurve (already in monetary units) at given power.

Returns total cost in \$/h including VOM costs.
"""
function evaluate_production_cost(cost_curve::PSY.CostCurve, active_power::Float64)
    isapprox(active_power, 0.0) && return 0.0

    # Get the value curve and evaluate it
    value_curve = PSY.get_value_curve(cost_curve)
    total_cost = evaluate_value_curve(value_curve, active_power)

    # Add VOM cost if present
    vom = PSY.get_vom_cost(cost_curve)
    if !isnothing(vom) && vom isa IS.LinearCurve
        vom_cost = IS.get_proportional_term(vom) * active_power
        total_cost += vom_cost
    end

    return total_cost
end

"""
    evaluate_production_cost(fuel_curve::PSY.FuelCurve, active_power::Float64)

Evaluate a FuelCurve (fuel consumption) at given power and convert to cost.

Returns total cost in \$/h including fuel cost and VOM costs.

Note: This only works for constant fuel prices. Time-varying fuel prices
require additional time series information.
"""
function evaluate_production_cost(fuel_curve::PSY.FuelCurve, active_power::Float64)
    isapprox(active_power, 0.0) && return 0.0

    # Get the value curve (in fuel units) and evaluate it
    value_curve = PSY.get_value_curve(fuel_curve)
    total_fuel = evaluate_value_curve(value_curve, active_power)

    # Convert fuel consumption to cost
    fuel_cost = PSY.get_fuel_cost(fuel_curve)
    if fuel_cost isa Float64
        total_cost = total_fuel * fuel_cost
    else
        # If fuel_cost is a TimeSeriesKey, we can't evaluate it without time context
        error("Cannot evaluate time-varying fuel cost without time series context")
    end

    # Add VOM cost if present
    vom = PSY.get_vom_cost(fuel_curve)
    if !isnothing(vom) && vom isa IS.LinearCurve
        vom_cost = IS.get_proportional_term(vom) * active_power
        total_cost += vom_cost
    end

    return total_cost
end

function get_marginal_cost_at_max_power(generator::PSY.Generator)
    0.0
end

"""
    get_marginal_cost_at_max_power(generator::PSY.Generator)

Get marginal cost at maximum active power for merit order dispatch.

Computes average cost = total_cost / max_power as an estimate of marginal cost.
This is suitable for sorting generators in merit order.

# Arguments

  - `generator::PSY.Generator`: Generator to evaluate

# Returns

  - `Float64`: Marginal cost in \$/MWh at max power
"""
function get_marginal_cost_at_max_power(
    generator::Union{PSY.ThermalGen, PSY.RenewableDispatch, PSY.HydroDispatch},
)
    op_cost = PSY.get_operation_cost(generator)

    variable_cost = PSY.get_variable(op_cost)
    max_power = PSY.get_max_active_power(generator)

    if max_power <= 0.0
        return 0.0
    end

    # Evaluate cost curve at max power - let errors propagate
    total_cost = evaluate_production_cost(variable_cost, max_power)
    return total_cost / max_power
end
