package org.camunda.tngp.broker.it.taskqueue;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import org.camunda.tngp.broker.it.ClientRule;
import org.camunda.tngp.broker.it.EmbeddedBrokerRule;
import org.camunda.tngp.broker.it.util.ParallelRequests;
import org.camunda.tngp.broker.it.util.ParallelRequests.SilentFuture;
import org.camunda.tngp.client.AsyncTasksClient;
import org.camunda.tngp.client.TngpClient;
import org.camunda.tngp.client.cmd.BrokerRequestException;
import org.camunda.tngp.client.cmd.LockedTask;
import org.camunda.tngp.client.cmd.LockedTasksBatch;
import org.junit.Ignore;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.ExpectedException;
import org.junit.rules.RuleChain;
import org.junit.rules.Timeout;

/**
 * Tests the entire cycle of task creation, polling and completion as a smoke test for when something gets broken
 *
 * @author Lindhauer
 */
public class TaskQueueTest
{
    public EmbeddedBrokerRule brokerRule = new EmbeddedBrokerRule();

    public ClientRule clientRule = new ClientRule();

    @Rule
    public RuleChain ruleChain = RuleChain
        .outerRule(brokerRule)
        .around(clientRule);

    @Rule
    public ExpectedException thrown = ExpectedException.none();

    @Rule
    public Timeout testTimeout = Timeout.seconds(10);

    @Test
    public void shouldCreateTask()
    {
        final TngpClient client = clientRule.getClient();

        final Long taskKey = client.tasks().create()
            .topicId(0)
            .taskType("foo")
            .addHeader("k1", "a")
            .addHeader("k2", "b")
            .payload("{ \"payload\" : 123 }")
            .execute();

        assertThat(taskKey).isGreaterThanOrEqualTo(0);
    }

    @Test
    public void shouldFailCreateTaskIfTopicIdIsNotValid()
    {
        final TngpClient client = clientRule.getClient();

        thrown.expect(BrokerRequestException.class);
        thrown.expectMessage("Cannot execute command. Topic with id '999' not found");

        client.tasks().create()
            .topicId(999)
            .taskType("foo")
            .addHeader("k1", "a")
            .addHeader("k2", "b")
            .payload("{ \"payload\" : 123 }")
            .execute();
    }

    @Test
    @Ignore
    public void testCycle()
    {
        final TngpClient client = clientRule.getClient();
        final AsyncTasksClient taskService = client.tasks();

        System.out.println("Creating task");

        final Long taskId = taskService.create()
            .topicId(0)
            .payload("{}")
            .taskType("bar")
            .execute();

        assertThat(taskId).isGreaterThanOrEqualTo(0);

        System.out.println("Locking task");

        final LockedTasksBatch lockedTasksBatch = taskService.pollAndLock()
            .taskQueueId(0)
            .taskType("bar")
            .lockTime(100 * 1000)
            .execute();

        assertThat(lockedTasksBatch.getLockedTasks()).hasSize(1);

        final LockedTask task = lockedTasksBatch.getLockedTasks().get(0);
        assertThat(task.getId()).isEqualTo(taskId);

        System.out.println("Completing task");

        final Long completedTaskId = taskService.complete()
            .topicId(0)
            .taskKey(taskId)
            .execute();

        assertThat(completedTaskId).isEqualTo(taskId);
    }

    @Test
    @Ignore
    public void testCannotCompleteUnlockedTask()
    {
        final TngpClient client = clientRule.getClient();
        final AsyncTasksClient taskService = client.tasks();

        final Long taskId = taskService.create()
            .topicId(0)
            .payload("{}")
            .taskType("bar")
            .execute();

        assertThat(taskId).isGreaterThanOrEqualTo(0);

        thrown.expect(BrokerRequestException.class);
        thrown.expectMessage("Task does not exist or is not locked");

        taskService.complete()
            .topicId(0)
            .taskKey(taskId)
            .execute();
    }

    @Test
    @Ignore
    public void testCannotCompleteTaskTwiceInParallel()
    {
        // given
        final TngpClient client = clientRule.getClient();
        final AsyncTasksClient taskClient = client.tasks();

        final Long taskId = taskClient.create()
            .topicId(0)
            .payload("foo")
            .taskType("bar")
            .execute();

        taskClient.pollAndLock()
            .taskQueueId(0)
            .taskType("bar")
            .lockTime(Duration.ofHours(1L))
            .execute();


        final ParallelRequests parallelRequests = ParallelRequests.prepare();

        final SilentFuture<Long> future1 = parallelRequests.submitRequest(
            () -> taskClient.complete()
                .topicId(0)
                .taskKey(taskId)
                .execute());

        final SilentFuture<Long> future2 = parallelRequests.submitRequest(
            () -> taskClient.complete()
                .topicId(0)
                .taskKey(taskId)
                .execute());

        // when
        parallelRequests.execute();

        // then
        final Set<Long> results = new HashSet<>();
        results.add(future1.get());
        results.add(future2.get());

        assertThat(results).contains(taskId, null);
    }

    @Test
    @Ignore
    public void testLockZeroTasks()
    {
        // given
        final AsyncTasksClient taskService = clientRule.getClient().tasks();

        // when
        final LockedTasksBatch lockedTasksBatch = taskService.pollAndLock()
                .taskQueueId(0)
                .taskType("bar")
                .lockTime(100 * 1000)
                .execute();

        // when
        assertThat(lockedTasksBatch.getLockedTasks()).isEmpty();
    }

    @Test
    @Ignore
    public void testLockTaskWithPayload()
    {
        // given
        final TngpClient client = clientRule.getClient();
        final AsyncTasksClient taskService = client.tasks();

        System.out.println("Creating task");

        final Long taskId = taskService.create()
            .topicId(0)
            .payload("foo")
            .taskType("bar")
            .execute();

        // when
        final LockedTasksBatch lockedTasksBatch = taskService.pollAndLock()
            .taskQueueId(0)
            .taskType("bar")
            .lockTime(10000L)
            .execute();

        // then
        assertThat(lockedTasksBatch).isNotNull();

        final List<LockedTask> tasks = lockedTasksBatch.getLockedTasks();
        assertThat(tasks).hasSize(1);
        assertThat(tasks.get(0).getId()).isEqualTo(taskId);
        assertThat(tasks.get(0).getPayloadString()).isEqualTo("foo");

    }

}