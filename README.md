# audited-mongoid

# 使用方法

```ruby 
class Model < ActiveRecord::Base
    MONGO_EXPIRE_AFTER_SECONDS = 30.days # mongo中日志保留时间
    include Audited # 引入审计模块
    audited  # 调用审计初始化方法
  end
```

### audited 方法使用
 监控所有字段(不包含默认忽略字段， 例如：created_at updated_at...)
```ruby
audited
```

监控单一字段
```ruby
audited only: :name
```

监控多个字段

```ruby
audited only: [:name, :address]
```

除某些字段外的所有字段
```ruby
audited except: :password
```