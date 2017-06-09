using Documenter, AWSClusterManagers

makedocs(
    modules = [AWSClusterManagers],
    format = :html,
    pages = [
        "Home" => "index.md",
        "Batch" => "pages/batch.md",
        "ECS" => "pages/ecs.md",
        "Design" => "pages/design.md",
        "API" => "pages/api.md",
    ],
    repo = "https://gitlab.invenia.ca/invenia/AWSClusterManagers.jl/blob/{commit}{path}#L{line}",
    sitename = "AWSClusterManagers.jl",
    authors = "Curtis Vogt",
    assets = [
        "assets/invenia.css",
        "assets/batch_workers.svg",
        "assets/batch_managers.svg",
        "assets/batch_project.svg",
    ],
)
