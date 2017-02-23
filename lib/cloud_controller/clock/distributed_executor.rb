module VCAP::CloudController
  class DistributedExecutor
    def initialize
      @logger = Steno.logger('cc.clock')
    end

    def execute_job(name:, interval:, fudge:, timeout:)
      ensure_job_record_exists(name)

      ClockJob.db.transaction do
        job = ClockJob.find(name: name).lock!

        need_to_run_job = need_to_run_job?(job, interval, timeout, fudge)

        if need_to_run_job
          @logger.info("Queueing #{name} at #{now}")
          record_job_started(job)
          yield
          record_job_completed(job)
        end
      end
    end

    private

    def record_job_started(job)
      job.update(last_started_at: now)
    end

    def record_job_completed(job)
      job.update(last_completed_at: now)
    end

    def ensure_job_record_exists(job_name)
      ClockJob.find_or_create(name: job_name)
    rescue Sequel::UniqueConstraintViolation
      # find_or_create is not safe for concurrent access
    end

    def need_to_run_job?(job, interval, timeout, fudge=0)
      last_started_at = job.last_started_at
      last_completed_at = job.last_completed_at
      @logger.info "Job last started at #{last_started_at}. Last completed at #{last_completed_at} Interval: #{interval}"
      if last_started_at.nil?
        return true
      end
      interval_has_elapsed = now >= (last_started_at + interval - fudge)
      last_run_completed = last_completed_at && (last_completed_at >= last_started_at)
      timeout_elapsed = timeout && (now >= (last_started_at + timeout))

      interval_has_elapsed && (last_run_completed || timeout_elapsed)
    end

    def now
      Time.now.utc
    end
  end
end
