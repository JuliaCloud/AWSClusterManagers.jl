using Documenter, AWSClusterManagers

makedocs(
    modules = [AWSClusterManagers],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        assets = [
            "assets/invenia.css",
            "assets/figures/batch_workers.svg",
            "assets/figures/batch_managers.svg",
            "assets/figures/batch_project.svg",
            "assets/figures/docker_manager.svg",
        ],
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
