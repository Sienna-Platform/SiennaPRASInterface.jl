using Documenter
import DataStructures: OrderedDict
using SiennaPRASInterface
using SiennaPRASInterface.PRASCore

pages = OrderedDict(
    "Welcome Page" => "index.md",
    "How to..." =>
        Any["How do I add outage data?" => "how_to_guides/how_do_i_add_outage_data.md"],
    "Explanations" =>
        Any["Default outage values" => "explanations/default_outage_values.md"],
    "Reference" => Any[
        "Public API Reference" => "api/public.md",
        "Internal API Reference" => "api/internal.md",
    ],
)

makedocs(
    modules=[SiennaPRASInterface, PRASCore],
    format=Documenter.HTML(
        prettyurls=haskey(ENV, "GITHUB_ACTIONS"),
        size_threshold=nothing,
    ),
    sitename="github.com/Sienna-Platform/SiennaPRASInterface.jl",
    authors="Surya Dhulipala, Joseph McKinsey, José Daniel Lara",
    pages=Any[p for p in pages],
    warnonly=true,
)

deploydocs(
    repo="github.com/Sienna-Platform/SiennaPRASInterface.jl.git",
    target="build",
    branch="gh-pages",
    devbranch="main",
    devurl="dev",
    push_preview=true,
    versions=["stable" => "v^", "v#.#"],
)
