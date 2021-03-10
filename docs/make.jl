using Documenter, AWSClusterManagers

makedocs(;
    modules = [AWSClusterManagers],
    authors = "Invenia Technical Computing Corporation",
    repo = "https://github.com/JuliaCloud/AWSClusterManagers.jl/blob/{commit}{path}#L{line}",
    sitename = "AWSClusterManagers.jl",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
    pages = [
        "Home" => "index.md",
        "Docker" => "pages/docker.md",
        "Batch" => "pages/batch.md",
        "ECS" => "pages/ecs.md",
        "Design" => "pages/design.md",
        "API" => "pages/api.md",
    ],
    strict = true,
    checkdocs = :exports,
)

deploydocs(;
    repo = "github.com/JuliaCloud/AWSClusterManagers.jl",
    devbranch = "main",
    push_preview = true,
)
