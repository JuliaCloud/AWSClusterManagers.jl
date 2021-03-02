using Documenter, AWSClusterManagers

makedocs(
    modules = [AWSClusterManagers],
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
    repo = "https://github.com/JuliaCloud/AWSClusterManagers.jl/blob//{commit}{path}#L{line}",
    sitename = "AWSClusterManagers.jl",
    authors = "Invenia Technical Computing",
    checkdocs = :exports,
    strict = true,
)
