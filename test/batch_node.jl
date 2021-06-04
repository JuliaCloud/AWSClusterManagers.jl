@testset "AWSBatchNodeManager" begin
    @testset "AWS_BATCH_JOB_ID DNE" begin
        withenv(
            "AWS_BATCH_JOB_MAIN_NODE_INDEX" => 1
        ) do
            @test_throws ErrorException AWSBatchNodeManager()
        end
    end

    @testset "AWS_BATCH_JOB_MAIN_NODE_INDEX DNE" begin
        withenv(
            "AWS_BATCH_JOB_ID" => "job_id"
        ) do
            @test_throws ErrorException AWSBatchNodeManager()
        end
    end

    @testset "AWS_BATCH_JOB_NUM_NODES DNE" begin
        withenv(
            "AWS_BATCH_JOB_ID" => "job_id",
            "AWS_BATCH_JOB_NODE_INDEX" => 1,
            "AWS_BATCH_JOB_MAIN_NODE_INDEX" => 1,
        ) do
            @test_throws KeyError AWSBatchNodeManager()
        end
    end

    @testset "AWS_BATCH_JOB_NODE_INDEX != AWS_BATCH_JOB_MAIN_NODE_INDEX" begin
        withenv(
            "AWS_BATCH_JOB_ID" => "job_id",
            "AWS_BATCH_JOB_NODE_INDEX" => 0,
            "AWS_BATCH_JOB_MAIN_NODE_INDEX" => 1
        ) do
            @test_throws ErrorException AWSBatchNodeManager()
        end
    end

    @testset "AWS_BATCH_JOB_NUM_NODES -- String" begin
        withenv(
            "AWS_BATCH_JOB_ID" => "job_id",
            "AWS_BATCH_JOB_MAIN_NODE_INDEX" => 1,
            "AWS_BATCH_JOB_NODE_INDEX" => 1,
            "AWS_BATCH_JOB_NUM_NODES" => "foobar"
        ) do
            @test_throws ArgumentError AWSBatchNodeManager()
        end
    end

    @testset "AWS_BATCH_JOB_NUM_NODES -- Int" begin
        expected_workers = 9

        withenv(
            "AWS_BATCH_JOB_ID" => "job_id",
            "AWS_BATCH_JOB_MAIN_NODE_INDEX" => 1,
            "AWS_BATCH_JOB_NODE_INDEX" => 1,
            "AWS_BATCH_JOB_NUM_NODES" => expected_workers + 1  # Add one to account for the manager
        ) do
            result = AWSBatchNodeManager()

            @test result.num_workers == expected_workers
            @test result.timeout == AWSClusterManagers.AWS_BATCH_NODE_TIMEOUT
        end
    end

    @testset "AWS_BATCH_JOB_NUM_NODES -- Int" begin
        expected_workers = 9
        expected_timeout = Second(5)

        withenv(
            "AWS_BATCH_JOB_ID" => "job_id",
            "AWS_BATCH_JOB_MAIN_NODE_INDEX" => 1,
            "AWS_BATCH_JOB_NODE_INDEX" => 1,
            "AWS_BATCH_JOB_NUM_NODES" => expected_workers + 1  # Add one to account for the manager
        ) do
            result = AWSBatchNodeManager(; timeout=expected_timeout)

            @test result.num_workers == expected_workers
            @test result.timeout == expected_timeout
        end
    end
end

@testset "parse_job_id" begin
    passing_cases = [
        string(repeat("a", 36), "#123"),
        string("0-", repeat("a", 34), "#123")
    ]

    @testset "passing case: $(case)" for case in passing_cases
        str = string("job_id:", case)

        @test AWSClusterManagers.parse_job_id(str) == case
    end

    failing_cases = [
        string(repeat("a", 35), "#123"),
        string(repeat("a", 37), "#123"),
        string(repeat("!", 36), "#123"),
        string(repeat("a", 36), "#"),
        string(repeat("a", 36), "#abc"),
    ]

    @testset "failing case: $(case)" for case in failing_cases
        str = string("job_id:", case)

        @test_throws ErrorException AWSClusterManagers.parse_job_id(str)
    end
end

@testset "parse_cookie" begin
    @test AWSClusterManagers.parse_cookie("julia_cookie:1000") == "1000"
    @test AWSClusterManagers.parse_cookie("julia_cookie:1.5") == "1"
    @test AWSClusterManagers.parse_cookie("julia_cookie:foobar") == "foobar"

    @test_throws ErrorException AWSClusterManagers.parse_cookie("julia_cookie:-1")
    @test_throws ErrorException AWSClusterManagers.parse_cookie("foobar")
    @test_throws ErrorException AWSClusterManagers.parse_cookie("foobar:julia_cookie:1")
end


@testset "parse_worker_timeout" begin
    @test AWSClusterManagers.parse_worker_timeout("julia_worker_timeout:1000") == 1000
    @test AWSClusterManagers.parse_worker_timeout("julia_worker_timeout:1.5") == 1

    @test_throws ErrorException AWSClusterManagers.parse_worker_timeout("julia_worker_timeout:-1")
    @test_throws ErrorException AWSClusterManagers.parse_worker_timeout("julia_worker_timeout:foobar")
    @test_throws ErrorException AWSClusterManagers.parse_worker_timeout("foobar")
    @test_throws ErrorException AWSClusterManagers.parse_worker_timeout("foobar:julia_worker_timeout:1")
end
