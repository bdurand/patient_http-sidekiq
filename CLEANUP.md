# Plan: Processor Class Code Review & Cleanup

Analyze the Processor class - the core async HTTP reactor engine - identifying problematic code, documentation issues, abandoned features, and test gaps. Output findings to CLEANUP.md.

## Steps

1. Remove unused code:
  [x] a. The private resolve_worker_class method (around line 250) is never called - all sites use ClassHelper.resolve_class_name directly.
  [x] b. Remove read_timeout and write_timeout from Request and default_read_timeout and default_write_timeout from Configuration.

2. Flag thread safety concerns around state transitions:
  [x] a. In processor.rb:73 the state changes from :stopping (outside lock) to :stopped (inside lock) creating a brief inconsistency window that other methods reading @state could observe.

3. Identify error handling gaps:
  [ ] a. In both stop() and handle_error, Redis failures during worker re-enqueue are logged but silently swallowed in production (lines ~95, ~220). Jobs could be permanently lost during shutdown if Redis is unavailable.

4. Magic numbers that should be constants:
  [x] a. 0.1 dequeue timeout,
  [x] b. 5 second inflight update interval,
  [x] c. 0.01 reactor sleep - these are scattered throughout process_requests and should be extracted.

5. YARD documentation issues:
  [x] a. Per AGENTS.md convention, ensure blank lines between description and tags.
  [x] b. Also document @raise tags for methods throwing NotRunningError and MaxCapacityError.

6. Identify missing tests in processor_spec.rb:
  [x] a. No coverage for drained? predicate
  [x] b. ResponseTooLargeError behavior
  [x] c. Also note redundant error-type tests (lines ~760-790) that could be parameterized.
  [x] d. No test for idle connection timeout and connection timeout on requests

## Further Considerations

7. Method complexity:
  [x] a. Refactored process_request by extracting read_response_body method. The stop() and run_reactor() methods are left as-is since breaking them up would reduce clarity of their core flows.

8. Singleton pattern:
  [x] b. Documented the singleton processor pattern as an intentional design decision driven by Sidekiq integration, resource management, and operational simplicity. Added comprehensive documentation to the main module explaining rationale and trade-offs.
