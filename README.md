# audited-mongoid

此项目是基于 `collectiveidea/audited` `ActiveRecord`版本魔改而来
再次基础上实现了mongoid版本，且对多模型日志进行分集合存储。仅需要简单的设置即可使用。

# 使用方法
1.首先保证你已经安装了 mongo并启动，同时在项目中安装了 `gem` `mongoid` 

```ruby
gem 'mongoid', '5.4.1'
```

2.模型中创建 `model` `abstract_mongodb_class.rb`

```ruby
class AbstractMongodbClass
end
```

3.模型中创建 `model` `audited.rb` 然后把项目中audited内容复制过去

4.如果你希望记录操作者可以在`application_controller.rb`中添加`set_request_params`方法，以便在线程中读取请求信息

```ruby
def set_request_params
  Util.thread_cached_params[Audited::CONTROLLER_REQUEST] = request
end
```

### 模型引入
模型引入`audited`后`mongo`库中会自动创建一个集合`user_audit_logs`,并设置了日志的保留时间(需要在`mongo`中建立索引后生效)
，建立索引后日志会在到期时自动删除，而无需像`ActiveRecord`版本那样手动删除以减轻对`msyql`的压力。

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

监控除某些字段外的所有字段
```ruby
audited except: :password
```