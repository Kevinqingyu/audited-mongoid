
module Util
  THREAD_CACHED_PARAMS = "THREAD_CACHED_PARAMS"

  def thread_cached_params
    if Thread.current[THREAD_CACHED_PARAMS].blank?
      Thread.current[THREAD_CACHED_PARAMS] = {}
    end
    Thread.current[THREAD_CACHED_PARAMS]
  end

  def clear_thread_cached_params
    Thread.current[THREAD_CACHED_PARAMS] = {}
  end
end