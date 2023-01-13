# 问题现象描述
消息系统采用了 rocketmq 作为消息中间件 同时采用了 lettuce  作为redis的驱动包。
当追踪问题需要打印 lettuce的 日志的时候，发现日志级别设置无效。
具体表现为，logback文件中如下设置无效，并不能输出相应等级的日志。

```xml
    <logger name="io.lettuce.core" level="DEBUG" additivity="false">
        <appender-ref ref="async_file"/>
    </logger>
```

# 问题原因及追查方法
1. 排查法： 其他的第三方组件如 springframework ，r2dbc 的日志级别设置均有效。 排除了日志组件设置错误的问题。
2. 差异对比法: spring framework 单独使用 lettuce 的时候，是有日志输出的。
3. 调试追踪法: 找一段 该包中的代码，如  io.lettuce.core.protocol.CommandHandler  

```java
    private static final InternalLogger logger = InternalLoggerFactory.getInstance(CommandHandler.class);  //line 68

    private static final AtomicLong COMMAND_HANDLER_COUNTER = new AtomicLong();

    private final ClientOptions clientOptions;

    private final ClientResources clientResources;

    private final Endpoint endpoint;

    private final ArrayDeque<RedisCommand<?, ?, ?>> stack = new ArrayDeque<>();

    private final long commandHandlerId = COMMAND_HANDLER_COUNTER.incrementAndGet();

    private final RedisStateMachine rsm = new RedisStateMachine();

    private final boolean traceEnabled = logger.isTraceEnabled();

    private final boolean debugEnabled = logger.isDebugEnabled();  //line 86
```

在 line 68和 86 处设置断点，观测到  logger的 level 字段是空的。 
追踪logger 对象的创建， 发现其为默认工厂创建。

```java
netty-common-4.1.50.Final-sources.jar!\io\netty\util\internal\logging\InternalLoggerFactory.java
    public static InternalLoggerFactory getDefaultFactory() {
        if (defaultFactory == null) {
            defaultFactory = newDefaultFactory(InternalLoggerFactory.class.getName());
        }
        return defaultFactory;
    }

    /**
     * Changes the default factory.
     */
    public static void setDefaultFactory(InternalLoggerFactory defaultFactory) {
        InternalLoggerFactory.defaultFactory = ObjectUtil.checkNotNull(defaultFactory, "defaultFactory");
    }

    /**
     * Creates a new logger instance with the name of the specified class.
     */
    public static InternalLogger getInstance(Class<?> clazz) {
        return getInstance(clazz.getName());
    }

    /**
     * Creates a new logger instance with the specified name.
     */
    public static InternalLogger getInstance(String name) {
        return getDefaultFactory().newInstance(name);
    }

```

而该默认工厂，在 NettyRemotingAbstract 的 类初始化中被强制设定。并且是设定在 netty的lib类的。
NettyBridgeLoggerFactory 是rocketmq 的内部实现。
```java
\org\apache\rocketmq\remoting\netty\NettyRemotingAbstract.java  line 106

  static {
        NettyLogger.initNettyLogger();
    }

rocketmq-remoting-4.6.0-sources.jar!\org\apache\rocketmq\remoting\netty\NettyLogger.java line 36

    public static void initNettyLogger() {
        if (!nettyLoggerSeted.get()) {
            try {
                io.netty.util.internal.logging.InternalLoggerFactory.setDefaultFactory(new NettyBridgeLoggerFactory());
            } catch (Throwable e) {
                //ignore
            }
            nettyLoggerSeted.set(true);
        }
    }
	
```

而通过 @Slj4j 注解 中获取的 logger 是 配置的binder slf4j在StaticLoggerBinder中创建的

```java
<init>:75, LoggerContext (ch.qos.logback.classic)
<init>:59, StaticLoggerBinder (org.slf4j.impl)
<clinit>:50, StaticLoggerBinder (org.slf4j.impl)
bind:150, LoggerFactory (org.slf4j)
performInitialization:124, LoggerFactory (org.slf4j)
getILoggerFactory:417, LoggerFactory (org.slf4j)
getLogger:362, LoggerFactory (org.slf4j)
getLogger:388, LoggerFactory (org.slf4j)

```
并通过 ContextAware将其设置给 logback。
所有的logger 都会通过 logcontext 创建，并缓存在logContext的cache中。
如 defaultLogContext 初始化时就塞进去了  ROOT 的logger。
```java
    public LoggerContext() {
        super();
        this.loggerCache = new ConcurrentHashMap<String, Logger>();

        this.loggerContextRemoteView = new LoggerContextVO(this);
        this.root = new Logger(Logger.ROOT_LOGGER_NAME, null, this);
        this.root.setLevel(Level.DEBUG);
        //这个cache 很重要，所有的logger 都会被保存在这里
        loggerCache.put(Logger.ROOT_LOGGER_NAME, root);  
        initEvaluatorMap();
        size = 1;
        this.frameworkPackages = new ArrayList<String>();
    }
```

@Slj4j  是通过 getLogger 来获取的，而这个方法调用 loggerFactory 拿到defautLogContext ，通过 拿到defautLogContext.getLogger方法进行获取。
```java
slf4j-api-1.7.30-sources.jar!\org\slf4j\LoggerFactory.java 
    public static Logger getLogger(String name) {
        ILoggerFactory iLoggerFactory = getILoggerFactory();
        return iLoggerFactory.getLogger(name);
    }
```
LogContext.getLogger 方法 实现的过程是，现在 cache中查找， 如果没有的话， 将会创建logger并返回， 注意，它不是创建一个logger，而是根据package name 依次创建， 比如 io.lettuce.core.xxxx ,将会创建  [io] [io.lettuce] [io.lettuce.core] [io.lettuce.core.xxx]
但会返回最后一个。

在 lettuce 的代码中如CommandHandler ，本身也是通过 netty的 InternalLoggerFactory 来获取 factory了获取 logger， 如果没有 rocketmq的话， 那它拿到的 factory 会是 defaultLogContext ，但使用了rocketmq后， netty的 defaultLogFactory 被设置成了 rocketmq的InternalLoggerFactory。 于是 所有在defaultLogContext 中已经设置好的 logger 在新的 factory 里面将取不到。包括其中就有日志级别。
因此 日志级别失效。



另外， rocketMqClient 用到了这自己的内部的innerLogger的实现， 需要通过 设置项来开启。

` -Drocketmq.client.logUseSlf4j=true `

```java
rocketmq-client-4.6.0-sources.jar!\org\apache\rocketmq\client\log\ClientLogger.java  line 50

    static {
        CLIENT_USE_SLF4J = Boolean.parseBoolean(System.getProperty(CLIENT_LOG_USESLF4J, "false"));
        if (!CLIENT_USE_SLF4J) {
            InternalLoggerFactory.setCurrentLoggerType(InnerLoggerFactory.LOGGER_INNER);
            CLIENT_LOGGER = createLogger(LoggerName.CLIENT_LOGGER_NAME);
            createLogger(LoggerName.COMMON_LOGGER_NAME);
            createLogger(RemotingHelper.ROCKETMQ_REMOTING);
        } else {
            CLIENT_LOGGER = InternalLoggerFactory.getLogger(LoggerName.CLIENT_LOGGER_NAME);
        }
    }
```
# 临时的解决方法

rocketmq 会在启动时 初始化，并抢先设置了 netty的 defaultLogFactory， 而 lettuce的使用netty的时机并不确定， 根据需求而来。 
本来这个问题很难解的，但是 initNettyLogger 有一个特性是 做了重复初始化的防御。 因此可以利用这个特性，让 rocketmq 抢先初始化，然后再手工设置 netty的 defaultLogFactory.
```java
    @PostConstruct
    public void clearFactory(){

        InternalLoggerFactory f;
        try {

            NettyLogger.initNettyLogger();
            f = new Slf4JLoggerFactory();
            ((Slf4JLoggerFactory) f).newInstance(InternalLoggerFactory.class.getName()).debug("Using SLF4J as the default logging framework");
            io.netty.util.internal.logging.InternalLoggerFactory.setDefaultFactory(f);
        }catch (Exception e){

        }
    }
```

# 正确的解决方法
提交一个pr,顺便谴责一下这种无耻的占用行为。