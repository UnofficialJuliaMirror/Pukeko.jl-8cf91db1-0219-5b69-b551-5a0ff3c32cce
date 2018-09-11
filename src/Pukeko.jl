# This file is a part of Pukeko.jl.
# License is MIT. https://github.com/IainNZ/Pukeko.jl

module Pukeko
    export @test, @test_throws, @parametric

    __precompile__(false)

    """
        TEST_PREFIX

    Functions with this string at the the start of their name will be treated as
    self-contained sets of tests.
    """
    const TEST_PREFIX = "test_"

    """
        TestException

    The `Exception`` thrown when a Pukeko test fails. Used by `run_tests` to
    distinguish between test errors and unexpected errors.
    """
    struct TestException <: Exception
        message::String
    end

    """
        test_true(value)

    Throws iff `value` is not `true`. Calls to this are generated by `@test`.
    """
    function test_true(value)
        if value != true
            throw(TestException("Expression did not evaluate to `true`: " *
                                string(value)))
        end
        return nothing
    end

    """
        test_equal(value_left, value_right)

    Test that `value_left` is equal to `value_right`. Calls to this are
    generated by `@test` for the case of `@test expr_left == expr_right`.
    """
    function test_equal(value_left, value_right)
        if value_left != value_right
            throw(TestException("Expression did not evaluate to `true`: " *
                                string(value_left) * " != " *
                                string(value_right)))
        end
        return nothing
    end

    """
        @test expression
    
    Test that `expression` is `true`.
    """
    macro test(expression)
        # If `expression` is of form `expr_left == expr_right` -> `test_equal`.
        # Otherwise, use `test_true`.
        if (expression.head == :call && expression.args[1] == :(==) &&
            length(expression.args) == 3)
            return quote
                test_equal($(esc(expression.args[2])),
                           $(esc(expression.args[3])))
            end
        end
        return quote
            test_true($(esc(expression)))
        end
    end

    """
        @test_throws exception_type expression
    
    Test that `expression` throws an exception of type `exception_type`.
    """
    macro test_throws(exception_type, expression)
        return quote
            exception_thrown = true
            try
                $(esc(expression))
                global exception_thrown = false
            catch exception
                expected_type = $(esc(exception_type))
                if exception isa expected_type
                    # Test passes
                else
                    throw(TestException("Expression threw exception of " *
                                        "type $(typeof(exception)), but " *
                                        "expected $(expected_type)"))
                end
            end
            if !exception_thrown
                throw(TestException("Expression did not throw an exception, " *
                                    "expected $(expected_type) exception"))
            end
        end
    end

    @static if VERSION >= v"0.7"
        compat_name(mod) = names(mod, all=true)
        import Printf: @sprintf
    else
        compat_name(mod) = names(mod, true)
    end

    """
        run_tests(module_to_test; fail_fast=false)
    
    Runs all the sets of tests in module `module_to_test`. Test sets are defined
    as functions with names that begin with `TEST_PREFIX`. A summary is printed
    after all test sets have been run and if there were any failures an
    exception is thrown.
    
    Configuration options:

      * If `fail_fast==false` (default), if any one test function fails, the
        others will still run. If `true`, testing will stop on the first
        failure. The commandline argument `--PUKEKO_FAIL_FAST` will override
        `fail_fast` to `true` for all `run_tests` calls.
      * If `timing==true` (default is `false`), print elapsed time and memory
        allocation statistics for every test function. The commandline
        argument `--PUKEKO_TIMING` will override `timing` to `true` for all
        `run_tests` calls.
      * If `match_name!=nothing` (default is `nothing`), only run tests that
        contain `match_name` in their names. The commandline argument
        `--PUKEKO_MATH=str` will override `match_name` to `str` for all
        `run_tests` calls.
    """
    function run_tests(module_to_test; fail_fast=false, timing=false,
                                       match_name=nothing)
        # Parse commandline arguments.
        for arg in ARGS
            if arg == "--PUKEKO_FAIL_FAST"
                fail_fast = true
            elseif arg == "--PUKEKO_TIMING"
                timing = true
            elseif startswith(arg, "--PUKEKO_MATCH")
                match_name = split(arg, "=")[2]
            end
        end
        # Get a clean version of module name for logging messages.
        module_name = string(module_to_test)
        if startswith(module_name, "Main.")
            module_name = module_name[6:end]
        end
        # Keep track of failures to summarize at end.
        test_failures = Dict{String, TestException}()
        test_elapsed_time = Dict{String, UInt64}()
        test_start_mem = Dict{String, Base.GC_Num}()
        test_end_mem = Dict{String, Base.GC_Num}()
        test_functions = 0
        for maybe_function in compat_name(module_to_test)
            maybe_function_name = string(maybe_function)
            # If not a test function, skip to next function.
            if !startswith(maybe_function_name, TEST_PREFIX)
                continue
            end
            # If it doesn't match, skip to next function.
            if match_name != nothing
                if !occursin(match_name, maybe_function_name)
                    continue
                end
            end
            # Track statistics for each test.
            test_functions += 1
            start_time = time_ns()
            if timing
                test_start_mem[maybe_function_name] = Base.gc_num()
            end
            # If we don't need to catch errors, don't even try.
            if fail_fast
                @eval module_to_test ($maybe_function)()
            else
                # Try to run the function. If it fails, figure out why.
                try
                    @eval module_to_test ($maybe_function)()
                catch test_exception
                    if isa(test_exception, TestException)
                        test_failures[maybe_function_name] = test_exception
                    else
                        println("Unexpected exception occurred in test ",
                                "function `$(maybe_function_name)` ",
                                "in module `$(module_name)`")
                        throw(test_exception)
                    end
                end
            end
            # Track statistics.
            if timing
                test_end_mem[maybe_function_name] = Base.gc_num()
            end
            test_elapsed_time[maybe_function_name] = time_ns() - start_time
        end
        # At least one test function failed, print out the exceptions.
        if length(test_failures) > 0
            println("Test failures occurred in module $(module_name)")
            println("Functions with failed tests:")
            for (function_name, test_exception) in test_failures
                println("    $(function_name): ", test_exception)
            end
            error("Some tests failed!")
        end
        # All passed, output statistics.
        total_time = sum(values(test_elapsed_time))
        println("$(test_functions) test function(s) ran successfully ",
                "in module $(module_name) ",
                @sprintf("(%.2f seconds)", total_time / 1e9))
        if timing
            # Sort by run time, descending.
            time_names = [(elapsed, function_name)
                          for (function_name, elapsed) in test_elapsed_time]
            sort!(time_names, rev=true)
            for (elapsed, function_name) in time_names
                gc_diff = Base.GC_Diff(test_end_mem[function_name],
                                       test_start_mem[function_name])
                print(function_name, ": ")
                Base.time_print(elapsed, gc_diff.allocd, gc_diff.total_time,
                                Base.gc_alloc_count(gc_diff))
                println()
            end
        end
    end

    """
        parametric(module_to_test, func, iterable)
    
    Create a version of `func` that is prefixed with `TEST_PREFIX` in
    `module_to_test` for each value in `iterable`. If a value in `iterable` is
    a tuple, it is splatted into the function arguments.
    """
    function parametric(module_to_test, func, iterable)
        for (index, value) in enumerate(iterable)
            func_name = Symbol(string(TEST_PREFIX, func, index))
            if value isa Tuple
                @eval module_to_test $func_name() = $func($(value)...)
            else
                @eval module_to_test $func_name() = $func($(value))
            end
        end
    end

    """
        @parametric func iterable
    
    Create a version of `func` that is prefixed with `TEST_PREFIX` in the module
    that this macro is called for each value in `iterable`. If a value in
    `iterable` is a tuple, it is splatted into the function arguments.
    """
    macro parametric(func, iterable)
        @static if VERSION >= v"0.7"
            module_ = __module__
        else
            module_ = current_module()
        end
        return quote
            parametric($(module_), $(esc(func)), $(esc(iterable)))
        end
    end
end
